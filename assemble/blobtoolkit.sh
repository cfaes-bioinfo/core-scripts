#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=4:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=blobtoolkit
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Build a BlobToolKit dataset (blob plot) combining assembly GC, read coverage and taxonomic assignment, to decide which contigs are contamination"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=blobtools
TOOL_NAME=BlobToolKit
TOOL_DOCS="https://blobtoolkit.genomehubs.org/blobtools2 | https://github.com/blobtoolkit/blobtoolkit"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=container
container_url=oras://community.wave.seqera.io/library/blobtoolkit:4.5.5--288421bb285e69a7
container_dir="$HOME/containers"
container_path=
conda_path=

# Constants - tool parameters
TAXDUMP_URL=https://ftp.ncbi.nlm.nih.gov/pub/taxonomy/new_taxdump/new_taxdump.tar.gz
# Bitscore given to every Kraken2-derived hit. Kraken2 assigns exactly one taxon
# per contig, so there is nothing for --taxrule to choose between and the value
# only has to clear BlobToolKit's default bitscore cutoff of 1.
KRAKEN_BITSCORE=100

# Defaults - tool parameters
bam=                        # --cov: BAM with reads mapped back to the assembly
kraken=                     # Kraken2 'main' output, converted to a hits file here
hits=                       # Ready-made BLAST/Diamond hits file (instead of --kraken)
taxdump=                    # NCBI new_taxdump dir (default: <outdir>/taxdump, downloaded if absent)
taxrule=bestsumorder        # --taxrule: how to assign hits to taxa
taxid=                      # --taxid: adds the assembly's own taxon ranks to the metadata
make_plots=true             # Attempt static plot images with 'blobtools view'

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "
                        $0
    v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL
            =================================================

DESCRIPTION:
$DESCRIPTION

A blob plot puts GC content on one axis and read coverage on the other, sizes
each point by contig length and colours it by taxonomy. Contaminants separate
out because they differ from the host in coverage AND composition at the same
time - which is why this is a better basis for filtering than either signal
alone. Compositional outliers that sit at host coverage are usually real host
sequence (rDNA arrays and other satellites, for instance).

TAXONOMY INPUT:
  BlobToolKit normally takes BLAST/Diamond hits against a large reference
  database. This script also accepts Kraken2 output via --kraken, and converts
  it to the minimal hits format that 'blobtools add --hits-cols' understands.
  That reuses a Kraken2 run you already have, at the cost of some sensitivity:
  Kraken2 leaves sequences unclassified when the host is absent from its
  database, so expect most host contigs to come out as 'no-hit'. That is fine
  for spotting contaminants, which is what this step is for.

USAGE / EXAMPLE COMMANDS:
  - From a Kraken2 run and a coverage BAM:
      sbatch $0 -i results/hifiasm/asm.fasta -o results/blobtoolkit \\
          --bam results/minimap/asm.bam --kraken results/kraken-asm/asm.main.txt
  - From a ready-made Diamond/BLAST hits file:
      sbatch $0 -i asm.fasta -o results/blobtoolkit --bam asm.bam --hits diamond.out

REQUIRED OPTIONS:
  -i/--infile         <file>  Input genome assembly FASTA file
  -o/--outdir         <dir>   Output dir (will be created if needed)
                              The BlobDir dataset goes in '<outdir>/blobdir'

OTHER KEY OPTIONS:
  --bam               <file>  BAM with reads mapped back to the assembly
                              (from map/minimap.sh)
  --kraken            <file>  Kraken2 'main' output file for the assembly
  --hits              <file>  BLAST/Diamond tabular hits file, used instead of
                              --kraken (expects 'outfmt 6 qseqid staxids bitscore std')
  --taxdump           <dir>   NCBI new_taxdump dir                              [default: <outdir>/taxdump]
                              Downloaded automatically if it is not there yet
  --taxrule           <str>   Rule for assigning hits to taxa                   [default: $taxrule]
  --taxid             <int>   Taxon ID of the assembled organism                [default: none]
  --no_plots                  Skip the static plot images                       [default: attempt them]
  --more_opts         <str>   Quoted string with one or more additional options
                              for 'blobtools add'

OUTPUT:
  <outdir>/blobdir/           - The BlobDir dataset (view with 'blobtools host')
  <outdir>/blobdir.tsv        - Per-contig table: GC, length, coverage, taxonomy
  <outdir>/*.png              - Blob and snail plots, if they could be rendered
  Alongside those, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:
  --env_type          <str>   Software environment: 'conda', 'container'        [default: $env_type]
                              (Singularity/Apptainer), or 'none' (tool must
                              already be available in your PATH)
  --container_url     <str>   URL/URI to download a container from              [default: ${container_url:-none}]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_path    <file>  Local container image file ('.sif') to use        [default: ${container_path:-none}]
  --conda_path        <dir>   Full path to a Conda environment to use           [default: ${conda_path:-none}]
  -h/--help                   Print this help message
  -v/--version                Print script and $TOOL_NAME versions

TOOL DOCUMENTATION: $TOOL_DOCS
"
}

# Function to source the script with Bash functions
source_function_script() {
    local is_slurm=${1:-false}

    if [[ "$is_slurm" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"
    function_script_path="$script_dir"/../dev/"$function_script_name"

    if [[ -s "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -s "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            tmp_script=$(mktemp "$function_script_name".XXXXXX)
            if ! wget -q "$FUNCTION_SCRIPT_URL" -O "$tmp_script"; then
                rm -f "$tmp_script"
                echo "ERROR: Failed to download $FUNCTION_SCRIPT_URL" >&2
                exit 1
            fi
            mv -f "$tmp_script" "$function_script_name"
        fi
        source "$function_script_name"
    fi

    if ! declare -F log_time check_val >/dev/null; then
        echo "ERROR: Sourced $function_script_name but its functions are missing" >&2
        echo "       (an outdated copy may be cached - try deleting it)" >&2
        exit 1
    fi
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "${SLURM_JOB_ID:-}" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script "$IS_SLURM"

# Report clearly if this script exits with a non-zero status
trap report_on_exit EXIT

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
version_only=false
infile=
outdir=
more_opts=
threads=

all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --bam )             check_val "$1" "${2:-}"; shift; bam=$1 ;;
        --kraken )          check_val "$1" "${2:-}"; shift; kraken=$1 ;;
        --hits )            check_val "$1" "${2:-}"; shift; hits=$1 ;;
        --taxdump )         check_val "$1" "${2:-}"; shift; taxdump=$1 ;;
        --taxrule )         check_val "$1" "${2:-}"; shift; taxrule=$1 ;;
        --taxid )           check_val "$1" "${2:-}"; shift; taxid=$1 ;;
        --no_plots )        make_plots=false ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )      check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )  check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
[[ -z "$TOOL_BINARY" ]] && die "TOOL_BINARY has not been set in this script"
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$infile" ]] && die "No input assembly specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input assembly $infile does not exist"
[[ -n "$bam" && ! -f "$bam" ]] && die "BAM file $bam does not exist"
[[ -n "$kraken" && ! -f "$kraken" ]] && die "Kraken2 output file $kraken does not exist"
[[ -n "$hits" && ! -f "$hits" ]] && die "Hits file $hits does not exist"
[[ -z "$bam" && -z "$kraken" && -z "$hits" ]] &&
    die "Nothing to add: give at least one of --bam, --kraken or --hits" "$all_opts"
[[ -n "$kraken" && -n "$hits" ]] &&
    log_time "NOTE: both --kraken and --hits were given; using --hits and ignoring --kraken"

check_outdir "$outdir"

# Define outputs based on script parameters
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
outdir_abs=$(realpath "$outdir")
BLOBDIR="$outdir_abs"/blobdir
TABLE_OUT="$outdir_abs"/blobdir.tsv
[[ -z "$taxdump" ]] && taxdump="$outdir_abs"/taxdump

log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input assembly FASTA:                     $infile"
echo "Output dir:                               $outdir_abs"
echo "BlobDir dataset:                          $BLOBDIR"
[[ -n "$bam" ]] && echo "Coverage BAM:                             $bam"
[[ -n "$kraken" ]] && echo "Kraken2 output:                           $kraken"
[[ -n "$hits" ]] && echo "Hits file:                                $hits"
echo "Taxdump dir:                              $taxdump"
echo "Taxrule:                                  $taxrule"
[[ -n "$taxid" ]] && echo "Taxon ID of the assembly:                 $taxid"
echo "Attempt static plots:                     $make_plots"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile" ${bam:+"$bam"} ${kraken:+"$kraken"} ${hits:+"$hits"}
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

# --- Convert the Kraken2 output to a minimal hits file, if needed ---
hits_cols=
if [[ -z "$hits" && -n "$kraken" ]]; then
    hits="$outdir_abs"/kraken_hits.tsv
    log_time "Converting the Kraken2 output to a BlobToolKit hits file..."
    # Kraken2 'main' output columns: C/U, seqID, taxID, length, LCA mapping.
    # Only classified rows ('C') carry a taxon; unclassified contigs are simply
    # left out, and BlobToolKit shows them as 'no-hit'.
    # taxIDs 1 (root) and 131567 (cellular organisms) are dropped as well: they
    # carry no rank, so they cannot be plotted, and they are what conserved rRNA
    # genes collapse to - i.e. they mark real rDNA contigs, not contaminants.
    awk -v OFS='\t' -v score="$KRAKEN_BITSCORE" \
        '$1 == "C" && $3 != 0 && $3 != 1 && $3 != 131567 { print $2, $3, score, 0 }' \
        "$kraken" > "$hits"
    # qstart/qend are dummy-mapped onto the (unused) evalue column: BlobToolKit's
    # 4-column 'minimal hits' path still unconditionally reads cols["qstart"]/
    # cols["qend"] and only catches IndexError, not the KeyError this raises when
    # they are absent - so they must resolve to *some* valid column, even a bogus one.
    hits_cols="1=qseqid,2=staxids,3=bitscore,4=evalue,4=qstart,4=qend"

    n_hits=$(wc -l < "$hits")
    n_contigs=$(grep -c "^>" "$infile")
    log_time "$n_hits of $n_contigs contigs got a taxonomic assignment from Kraken2"
    [[ "$n_hits" -eq 0 ]] &&
        log_time "WARNING: Kraken2 classified no contigs at all - the plot will have no taxonomy"
fi

# --- Get the NCBI taxdump, which BlobToolKit needs to resolve taxon IDs to ranks ---
if [[ -n "$hits" ]]; then
    if [[ -s "$taxdump"/nodes.dmp ]]; then
        log_time "Using the existing taxdump at $taxdump"
    else
        log_time "Downloading the NCBI new_taxdump to $taxdump..."
        mkdir -p "$taxdump"
        wget -q -O "$taxdump"/new_taxdump.tar.gz "$TAXDUMP_URL" ||
            die "Failed to download the taxdump from $TAXDUMP_URL"
        tar -xzf "$taxdump"/new_taxdump.tar.gz -C "$taxdump"
        rm -f "$taxdump"/new_taxdump.tar.gz
        [[ ! -s "$taxdump"/nodes.dmp ]] && die "The taxdump in $taxdump has no nodes.dmp"
    fi
fi

# --- Create the dataset ---
log_time "Creating the BlobDir dataset from the assembly..."
runstats $TOOL_BINARY create \
    --fasta "$infile" \
    ${taxid:+--taxid "$taxid"} \
    ${taxid:+--taxdump "$taxdump"} \
    "$BLOBDIR"

# --- Add coverage and taxonomy ---
log_time "Adding coverage and taxonomy to the dataset..."
eval runstats "$TOOL_BINARY" add \
    ${bam:+--cov "$(printf '%q' "$bam")"} \
    ${hits:+--hits "$(printf '%q' "$hits")"} \
    ${hits_cols:+--hits-cols "$hits_cols"} \
    ${hits:+--taxrule "$taxrule"} \
    ${hits:+--taxdump "$(printf '%q' "$taxdump")"} \
    --threads "$threads" \
    $more_opts \
    "$(printf '%q' "$BLOBDIR")"

# --- Export a per-contig table: this is what the exclusion list is built from ---
log_time "Exporting a per-contig table..."
runstats $TOOL_BINARY filter \
    --table "$TABLE_OUT" \
    --table-fields plot \
    ${hits:+--taxrule "$taxrule"} \
    "$BLOBDIR"

if [[ -s "$TABLE_OUT" ]]; then
    log_time "First lines of the per-contig table:"
    head -20 "$TABLE_OUT" | column -t -s $'\t' 2>/dev/null || head -20 "$TABLE_OUT"
else
    log_time "WARNING: no per-contig table was produced at $TABLE_OUT"
fi

# --- Static plots ---
# 'blobtools view' renders the plots through a headless browser, which often has
# no working setup on a compute node. Treat a failure as a warning, not an error:
# the dataset and the table above are the parts that the next steps actually need.
if [[ "$make_plots" == true ]]; then
    log_time "Attempting to render static plots with 'blobtools view'..."
    if runstats $TOOL_BINARY view \
            --view blob --view snail --view cumulative \
            --format png \
            --out "$outdir_abs" \
            "$BLOBDIR"; then
        log_time "Plots rendered"
    else
        log_time "WARNING: 'blobtools view' failed - this is usually the headless"
        log_time "         browser, not the dataset. The BlobDir itself is fine:"
        log_time "         view it interactively with 'blobtools host $BLOBDIR',"
        log_time "         or plot from $TABLE_OUT."
    fi
else
    log_time "NOTE: skipping the static plots because --no_plots was given"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$outdir_abs"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir_abs"
log_time "Next: pick the contigs to drop and list them in config/exclude-contigs.txt (step C6)"
final_reporting
