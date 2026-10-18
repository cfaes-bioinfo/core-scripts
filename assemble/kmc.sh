#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=4:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=72G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=kmc
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Count k-mers in HiFi reads with KMC3 and build a histogram for genome profiling (e.g. with GenomeScope2)"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=kmc
TOOL_NAME=KMC3
TOOL_DOCS=https://github.com/refresh-bio/KMC
VERSION_COMMAND="$TOOL_BINARY"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/kmc:3.2.4--c1c3a25b68789b0f
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
kmer_len=21                         # -k: k-mer length (21 is standard for genome profiling)
min_count=1                         # -ci: exclude k-mers occurring fewer times than this
max_count=10000                     # -cs/-cx: counter saturation / histogram cutoff
kmc_mem=64                          # -m: max memory (GB) KMC itself is allowed to use

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
  - Basic usage example:
      sbatch $0 -i results/hifiadapterfilt/sample.filt.fastq.gz -o results/kmc

REQUIRED OPTIONS:
  -i/--infile         <file>  Input gzipped FASTQ file
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --kmer-len          <int>   K-mer length                                     [default: $kmer_len]
  --min-count         <int>   Minimum k-mer count to retain (-ci)              [default: $min_count]
  --max-count         <int>   Counter saturation / histogram cutoff (-cs/-cx)  [default: $max_count]
  --kmc-mem           <int>   Max memory (GB) for KMC itself (-m)              [default: $kmc_mem]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

UTILITY OPTIONS:
  --env_type          <str>   Software environment: 'conda', 'container'        [default: $env_type]
                              (Singularity/Apptainer), or 'none' (tool must
                              already be available in your PATH)
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
    local is_slurm=${1:-false}

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
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -s "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -s "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            # Download to a temp file, then move into place, so that concurrent
            # jobs can never source a half-written file
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

    # Make sure the functions were really loaded
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
# Initiate variables
version_only=false  # When true, just print tool & script version info and exit
infile=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --kmer-len )        check_val "$1" "${2:-}"; shift; kmer_len=$1 ;;
        --min-count )       check_val "$1" "${2:-}"; shift; min_count=$1 ;;
        --max-count )       check_val "$1" "${2:-}"; shift; max_count=$1 ;;
        --kmc-mem )         check_val "$1" "${2:-}"; shift; kmc_mem=$1 ;;
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
# Check software env
[[ -z "$TOOL_BINARY" ]] && die "TOOL_BINARY has not been set in this script"
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

# Load software
load_env   # Note: reads the env_type/conda_path/container_* globals, takes no args
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"
sample_id=$(basename "$infile" | sed -E 's/\.(fastq\.gz|fq\.gz|fastq|fq)$//')
kmer_db="$outdir"/"${sample_id}"_k"${kmer_len}"
histfile="$outdir"/"${sample_id}"_k"${kmer_len}".histo
kmc_tmp="$outdir"/tmp
mkdir -p "$kmc_tmp"

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "Output dir:                               $outdir"
echo "K-mer length (-k):                        $kmer_len"
echo "Minimum k-mer count (-ci):                $min_count"
echo "Counter saturation / histo cutoff (-cs/-cx): $max_count"
echo "Memory for KMC (GB, -m):                  $kmc_mem"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file:"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# $TOOL_BINARY may include a container prefix (e.g. 'apptainer exec x.sif kmc');
# kmc_tools needs the same prefix, so it's built from $CONTAINER_PREFIX, which
# load_env sets as a side effect (empty string for conda/none env_type).
kmc_tools_bin="$CONTAINER_PREFIX kmc_tools"

log_time "Running $TOOL_NAME (counting k-mers)..."
eval runstats "$TOOL_BINARY" \
    -k"$kmer_len" \
    -t"$threads" \
    -m"$kmc_mem" \
    -ci"$min_count" \
    -cs"$max_count" \
    $more_opts \
    "$(printf '%q' "$infile")" \
    "$(printf '%q' "$kmer_db")" \
    "$(printf '%q' "$kmc_tmp")"

log_time "Running kmc_tools (building the k-mer count histogram)..."
eval runstats "$kmc_tools_bin" \
    transform "$(printf '%q' "$kmer_db")" \
    histogram "$(printf '%q' "$histfile")" \
    -cx"$max_count"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
