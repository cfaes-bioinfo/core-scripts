#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=dl_genomes
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Download genomes (and associated proteomes, annotations, etc) and associated metadata with the NCBI datasets tool"
SCRIPT_VERSION="2026-08-25"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=
TOOL_NAME="NCBI datasets"
TOOL_DOCS=https://www.ncbi.nlm.nih.gov/datasets/docs/v2/reference-docs/command-line/datasets
VERSION_COMMAND="datasets --version"

# Defaults - generics
env_type=container                # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/ncbi-datasets-cli:18.21.0--42e888b3fc6602f6
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
include="all"
ref_only=false
meta_only=false
assembly_version=latest
assembly_source=GenBank
move_output=true
meta_fields="accession,assminfo-name,organism-name,assminfo-refseq-category,assminfo-level,assmstats-number-of-contigs,assmstats-contig-n50,assminfo-sequencing-tech"


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
    
USAGE / EXAMPLE COMMANDS:
  - Download all C. elegans genomes:
      sbatch $0 --taxon 'Caenorhabditis elegans' -o results/refgenome

  - Download all reference nematode genomes:
      sbatch $0 --taxon 'nematoda' --ref_only -o results/refgenomes

  - Download geneomes using a file with a list of accessions:
      sbatch $0 --accession_file metadata/accession.txt -o results/refgenomes

  - Only download genome, annotation and proteome (default is to download all available files):
      sbatch $0 --taxon 'human' --include 'genome,protein,gff3' -o results

  - Download a single genome using its accession number:
      sbatch $0 --accession GCA_000001405.29 -o data/ref
    
REQUIRED OPTIONS:
  -o/--outdir         <dir>   Output dir (will be created if needed)
                              To specify genomes to download,
                              use _one_ of the following three options:
  -t/--taxon          <str>   Taxon string (e.g. 'bos taurus' or 'nematoda') or
                              NCBI Taxonomy ID (e.g. '10116')
  -a/--accession_file <file>  Text file with list of NCBI accession numbers,
                              one per line.
  -A/--accession      <str>   A single accession number to download
                              (e.g. 'GCA_003693625.1')
    
OTHER KEY OPTIONS:
  --as_is                     Don't move all files into the output dir, but     [default: move files]
                              keep subdir structure with one folder per genome.        
  --include           <str>   Comma-separated string with one or more of the    [default: $include]
                              following options:                                
                              'all' (all of the following), 'genome', 'rna',
                              'protein', 'cds', 'gff3', 'gtf', 'gbff',
                              'seq-report'
  --assembly_source   <str>   'GenBank', 'RefSeq', or 'all'                     [default: $assembly_source]
                                - 'GenBank' will likely return more records
                                - 'RefSeq' will likely return more annotations
                                   and proteomes 
                                - Does not apply when you're directly requestion
                                  GCA_ (GenBank) or GCF_ (RefSeq) accession nrs
  --assembly_version  <str>   'latest' or 'all'                                 [default: $assembly_version]
  --ref_only                  When specifying a taxon, only download genomes    [default: all matching genomes]
                              marked as 'reference genomes'.                               
  --meta_fields       <str>   Comma-separated list of metadata fields for the   [default: $meta_fields]
                              'selected' metadata output file. (A metadata file
                              with all possible metadata will also be produced.)                               
  --meta_only                 Don't download genomes, only metadata             [default: $meta_only]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME.
    
OUTPUT:
  Alongside the tool's own output, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:
  --env_type          <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                              ('container') or a Conda environment ('conda') 
  --container_url     <str>   URL to download a container from                  [default (if any): $container_url]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_path    <file>  Local container image file ('.sif') to use        [default (if any): $container_path]
  --conda_path        <dir>   Full path to a Conda environment to use           [default (if any): $conda_path]
  -h/--help                   Print this help message
  -v/--version                Print script and $TOOL_NAME versions
    
TOOL DOCUMENTATION:
  $TOOL_DOCS
"
}

# Function to source the script with Bash functions
source_function_script() {
    # NOTE: the argument is optional - some call sites pass none and rely on
    #       the IS_SLURM global instead
    local is_slurm=${1:-${IS_SLURM:-false}} candidate

    # Determine the location of this script, and based on that, the function script
    if [[ "$is_slurm" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"

    # Look for a local copy first, in order of preference, and only download as a
    # last resort: the download writes into the working dir, which many jobs share
    for candidate in "$script_dir"/../dev/"$function_script_name" \
                     "$script_dir"/../core-scripts/dev/"$function_script_name" \
                     "$function_script_name"; do
        if [[ -s "$candidate" ]]; then
            source "$candidate"
            check_functions_loaded
            return 0
        fi
    done

    # Download to a temp file, then move into place, so that concurrent jobs
    # can never source a half-written file
    echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
    tmp_script=$(mktemp "$function_script_name".XXXXXX)
    if ! wget -q "$FUNCTION_SCRIPT_URL" -O "$tmp_script"; then
        rm -f "$tmp_script"
        echo "ERROR: Failed to download $FUNCTION_SCRIPT_URL" >&2
        exit 1
    fi
    mv -f "$tmp_script" "$function_script_name"
    source "$function_script_name"
    check_functions_loaded
}

# Make sure the function script really provided the functions we rely on
check_functions_loaded() {
    if ! declare -F log_time check_val die load_env >/dev/null; then
        echo "ERROR: Sourced $function_script_name but its functions are missing" >&2
        echo "       (an outdated or truncated copy may be in the way - try deleting it)" >&2
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
# Initiate variables
version_only=false  # When true, just print tool & script version info and exit
accession_file=
accession=
taxon=
outdir=
more_opts=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o | --outdir )         check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        -t | --taxon )          check_val "$1" "${2:-}"; shift; taxon=$1 ;;
        -a | --accession_file ) check_val "$1" "${2:-}"; shift; accession_file=$1 ;;
        -A | --accession )      check_val "$1" "${2:-}"; shift; accession=$1 ;;
        --include )             check_val "$1" "${2:-}"; shift; include=$1 ;;
        --assembly_version )    check_val "$1" "${2:-}"; shift; assembly_version=$1 ;;
        --assembly_source )     check_val "$1" "${2:-}"; shift; assembly_source=$1 ;;
        --ref_only )            ref_only=true ;;
        --meta_fields )         check_val "$1" "${2:-}" lax; shift; meta_fields=$1 ;;
        --as_is )               move_output=false ;;
        --meta_only )           meta_only=true ;;
        --env_type )            check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )          check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )       check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )       check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )      check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version)         version_only=true ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check that this script's TODOs have been filled in
# NOTE: no TOOL_BINARY check here - in this script TOOL_BINARY is deliberately
#       empty, and only ever holds the container prefix (the 'datasets' and
#       'dataformat' subcommands are appended at each call site)
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

export NCBI_API_KEY=34618c91021ccd7f17429b650a087b585f08

# Print version info and exit, if requested (this needs the software env loaded)
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"       # Make absolute because we will move into the outdir
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"
meta_dir="$outdir"/metadata && mkdir -p "$meta_dir"
meta_all="$meta_dir"/meta_all.tsv
meta_sel="$meta_dir"/meta_sel.tsv

# Specify which file types to download
[[ "$include" == "all" ]] && include="cds,gbff,genome,gff3,gtf,protein,rna,seq-report"

# Build command to specify which genomes to download
if [[ -n "$accession_file" ]]; then
    accession_file=$(realpath "$accession_file")
    [[ ! -f "$accession_file" ]] && die "Input accession nr. file $accession_file does not exist"
    data_arg=(accession --inputfile "$accession_file")
    assembly_source=all
elif [[ -n "$accession" ]]; then
    data_arg=(accession "$accession")
    # If accession nr is GCA_ or GCF_, set --assembly-source to all
    if echo "$accession" | grep -q "GC[AF]_"; then
        log_time "The accession nr. contains GCA_/GCF_, so setting --assembly-source to 'all'"
        assembly_source=all
    fi
elif [[ -n "$taxon" ]]; then
    data_arg=(taxon "$taxon")
else
    die "Use either --accession, --accession_file, or --taxon to specify which genomes to download" "$all_opts"
fi

# Complete data arg
[[ "$ref_only" == true ]] && data_arg+=("--reference")
data_arg+=(--assembly-version "$assembly_version")
data_arg+=(--assembly-source "$assembly_source")

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Output dir:                               $outdir"
[[ -n "$taxon" ]] && echo "Taxon:                                    $taxon"
[[ -n "$accession_file" ]] && echo "Input file with accession list:           $accession_file"
[[ -n "$accession_file" ]] && echo "Number of input accessions:               $(wc -l < "$accession_file")"
echo "What to download for each genome:         $include"
echo "Assembly source (GenBank vs RefSeq):      $assembly_source"
echo "Download 'reference' genomes only:        $ref_only"
echo "Which assembly version(s) to download:    $assembly_version"
echo "Download metadata only?                   $meta_only"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
[[ -n "$accession_file" ]] && log_time "Listing the input file(s):"
[[ -n "$accession_file" ]] && ls -lh "$accession_file"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                          FUNCTIONS
# ==============================================================================
get_meta() {
    log_time "Storing *full* metadata on genomes in $meta_all..."
    runstats $TOOL_BINARY datasets summary genome "${data_arg[@]}" --as-json-lines |
        $TOOL_BINARY dataformat tsv genome > "$meta_all"

    log_time "Storing *selected* metadata on genomes in $meta_sel..."
    runstats $TOOL_BINARY datasets summary genome "${data_arg[@]}" --as-json-lines |
        $TOOL_BINARY dataformat tsv genome --fields "$meta_fields" > "$meta_sel"

    # Report metadata
    n_genomes=$(tail -n +2 "$meta_sel" | wc -l)
    log_time "Found $n_genomes genomes"
    log_time "Showing genome metadata file $meta_sel"
    column -ts $'\t' "$meta_sel"
}

dl_genomes() {
    log_time "Downloading the genomes..."
    runstats $TOOL_BINARY datasets download genome \
        "${data_arg[@]}" \
        --include "$include" \
        --filename genomes.zip \
        --no-progressbar \
        --api-key "$NCBI_API_KEY" \
        $more_opts

    # Process the output - unzip the archive
    log_time "Unzipping the downloaded archive..."
    unzip -q -o genomes.zip

    # Process the output - move the genomic data files
    if [[ "$move_output" == true ]]; then
        log_time "Moving and renaming the downloaded files..."

        while IFS= read -r -d '' file; do
            acc_nr=$(dirname "$file" | xargs basename)
            if [[ $(basename "$file") == "cds_from_genomic.fna" ]]; then
                # Make sure cds_from_genomic.fna is distinct from the genome fna
                outfile="$acc_nr"_cds.fasta
            elif [[ $(basename "$file") == "rna.fna" ]]; then
                outfile="$acc_nr"_rna.fasta
            else
                outfile="$acc_nr"."${file##*.}"
            fi
            mv -v "$file" "$outfile"
        done < <(find ncbi_dataset -type f -wholename "*data/GC*" -print0)

        echo
        echo "# Nr output nucleotide FASTAs:          $(find . -name "*.fna" | wc -l)"
        echo "# Nr output proteomes:                  $(find . -name "*.faa" | wc -l)"
        echo "# Nr output GFF files:                  $(find . -name "*.gff" | wc -l)"
        echo "# Nr output GTF files:                  $(find . -name "*.gtf" | wc -l)"
    fi

    # Report nr of input accessions again, for comparison
    [[ -n "$accession_file" ]] && log_time "Number of input accessions:                   $(wc -l < "$accession_file")"

    # Clean up
    log_time "Removing original ZIP file and NCBI's README file..."
    rm -r README.md genomes.zip
}

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# Move into the output dir
cd "$outdir" || exit 1

# Get metadata on genomes
get_meta

# Download the genomes
[[ "$meta_only" == false ]] && dl_genomes

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting
