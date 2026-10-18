#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=40
#SBATCH --mem=150G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=minimap
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Map long reads (or assemblies) to a reference with Minimap2, and produce a coordinate-sorted, indexed BAM plus per-contig coverage"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=minimap2
TOOL_NAME=Minimap2
TOOL_DOCS="https://lh3.github.io/minimap2 | https://github.com/lh3/minimap2"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=container
# This container has minimap2-2.31 and samtools-1.24:
container_url=oras://community.wave.seqera.io/library/minimap2_samtools:36e17b25d3087eff
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
preset=                     # -x: minimap2 preset - required, no default (see --help)
prefix=                     # Output file prefix (default: basename of the assembly)
sort_mem=4G                 # samtools sort -m: memory per sorting thread
sort_threads=               # samtools sort -@ (default: a quarter of the job's threads)

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

This script pipes Minimap2 straight into 'samtools sort', because the
intermediate SAM for a whole long-read run is far too large to write to disk.

It produces the coordinate-sorted and indexed BAM that BlobToolKit, Inspector and
purge_dups all need. It also writes a per-contig coverage table, which is the
main discriminator when deciding which contigs are contamination.

MEMORY NOTE:
  'samtools sort' uses up to (--sort_threads x --sort_mem) of memory on top of
  whatever Minimap2 needs for the index. With the defaults on a 40-core job that
  is 10 x 4G = 40 GB for sorting, which fits the 150G requested above.
  Raise '#SBATCH --mem' if you raise either option.

USAGE / EXAMPLE COMMANDS:
  - Basic usage:
      sbatch $0 -i data/hifi_reads.fastq.gz -r results/hifiasm/asm.fasta -x map-hifi -o results/minimap
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i reads.fastq.gz -r asm.fasta -x map-ont -o results/minimap --more_opts \"--secondary=no\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTQ (or FASTA) file with the reads
  -r/--ref            <file>  Reference FASTA file: the genome assembly to map to
  -x/--preset         <str>   Minimap2 preset ('-x'), e.g.:
                                map-hifi   PacBio HiFi reads
                                map-ont    Nanopore reads
                                map-pb     PacBio CLR reads
                                asm5/asm10/asm20  assembly vs reference, ~0.1/1/5% divergence
                                splice / splice:hq  spliced long-read alignment
                                sr         short reads
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --prefix            <str>   Output file prefix                                [default: basename of --ref]
  --sort_mem          <str>   Memory per 'samtools sort' thread ('-m')          [default: $sort_mem]
  --sort_threads      <int>   Threads for 'samtools sort' ('-@')                [default: a quarter of the job's threads]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<prefix>.bam           - Coordinate-sorted, indexed BAM
  <outdir>/<prefix>.coverage.tsv  - Per-contig mean depth, breadth and mean MAPQ
  <outdir>/<prefix>.flagstat.txt  - Alignment summary
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
ref=
outdir=
more_opts=
threads=

all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile | --reads )  check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -r | --ref | --reference ) check_val "$1" "${2:-}"; shift; ref=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        -x | --preset )     check_val "$1" "${2:-}"; shift; preset=$1 ;;
        --prefix )          check_val "$1" "${2:-}"; shift; prefix=$1 ;;
        --sort_mem )        check_val "$1" "${2:-}"; shift; sort_mem=$1 ;;
        --sort_threads )    check_val "$1" "${2:-}"; shift; sort_threads=$1 ;;
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
[[ -z "$infile" ]] && die "No input FASTQ specified, do so with -i/--infile" "$all_opts"
[[ -z "$ref" ]] && die "No reference FASTA specified, do so with -r/--ref" "$all_opts"
[[ -z "$preset" ]] && die "No Minimap2 preset specified, do so with -x/--preset" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input FASTQ $infile does not exist"
[[ ! -f "$ref" ]] && die "Reference FASTA $ref does not exist"

check_outdir "$outdir"

# Define outputs based on script parameters
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
[[ -z "$prefix" ]] && prefix=$(basename "$ref" | sed -E 's/\.(fa|fna|fas|fasta)(\.gz)?$//')
bam_out="$outdir"/"$prefix".bam
cov_out="$outdir"/"$prefix".coverage.tsv
flagstat_out="$outdir"/"$prefix".flagstat.txt
sort_tmp="${TMPDIR:-/tmp}"/"$prefix".sorttmp.$$

log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input FASTQ file:                         $infile"
echo "Reference (assembly) FASTA:               $ref"
echo "Output dir:                               $outdir"
echo "Output BAM file:                          $bam_out"
echo "Minimap2 preset:                          $preset"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile" "$ref"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# Now that 'threads' is known, work out the sorting threads
[[ -z "$sort_threads" ]] && sort_threads=$(( threads / 4 ))
[[ "$sort_threads" -lt 1 ]] && sort_threads=1
echo
echo "Threads for Minimap2:                     $threads"
echo "Threads for 'samtools sort':              $sort_threads"
echo "Memory per sorting thread:                $sort_mem"

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

# Samtools comes from the same container/env as Minimap2.
# NOTE: 'load_container' has already prepended the container prefix to TOOL_BINARY,
#       so only the Samtools calls need CONTAINER_PREFIX added by hand.
SAMTOOLS="${CONTAINER_PREFIX:-} samtools"

log_time "Running $TOOL_NAME, piping into 'samtools sort'..."
# 'bash -o pipefail' so that a Minimap2 failure is not masked by a successful sort
runstats bash -o pipefail -c "
    $TOOL_BINARY -a -x $preset -t $threads $more_opts \
        $(printf '%q' "$ref") $(printf '%q' "$infile") |
    $SAMTOOLS sort -@ $sort_threads -m $sort_mem \
        -T $(printf '%q' "$sort_tmp") -o $(printf '%q' "$bam_out")
"

log_time "Indexing the BAM file..."
runstats $SAMTOOLS index -@ "$threads" "$bam_out"
# Also write a .csi index: BlobToolKit's 'blobtools add --cov' only checks for
# a pre-existing .csi, and crashes trying to delete one it wrongly assumes it
# just created itself when only a .bai is present.
$SAMTOOLS index -c -@ "$threads" "$bam_out"

log_time "Computing per-contig coverage..."
$SAMTOOLS coverage "$bam_out" > "$cov_out"

log_time "Summarizing the alignments..."
$SAMTOOLS flagstat -@ "$threads" "$bam_out" > "$flagstat_out"
cat "$flagstat_out"

# Coverage is the main signal for spotting contaminant and organellar contigs,
# so show the extremes here rather than making the user open the file
log_time "Contigs with the LOWEST mean depth (candidate contaminants):"
awk 'NR == 1 { next } { print }' "$cov_out" |
    sort -k7,7g | head -10 |
    awk 'BEGIN { printf "  %-16s %10s %8s %8s\n", "contig", "length", "depth", "covered%" }
         { printf "  %-16s %10d %8.1f %8.1f\n", $1, $3, $7, $6 }'

log_time "Contigs with the HIGHEST mean depth (candidate organellar/repeat contigs):"
awk 'NR == 1 { next } { print }' "$cov_out" |
    sort -k7,7gr | head -10 |
    awk 'BEGIN { printf "  %-16s %10s %8s %8s\n", "contig", "length", "depth", "covered%" }
         { printf "  %-16s %10d %8.1f %8.1f\n", $1, $3, $7, $6 }'

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
rm -f "$sort_tmp"*.bam 2>/dev/null || true
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
