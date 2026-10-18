#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --gpus-per-node=2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=FAIL
#SBATCH --job-name=dorado-correct2
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Use Dorado to correct ONT reads via all-to-all alignment - part 2 of 2 (GPU inference step, using the PAF file from part 1)"
SCRIPT_VERSION="2026-09-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="/fs/ess/PAS0471/software/dorado/dorado-2.1.2-linux-x64/bin/dorado"
TOOL_NAME=Dorado
TOOL_DOCS=https://github.com/nanoporetech/dorado
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=none                      # Dorado is run from a fixed absolute path (not Conda/container);
                                   # 'none' just tells load_env()/final_reporting() to skip both

# Defaults - tool parameters
index_size=4G                      # Amount of memory for indexing, per core

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
      sbatch $0 -i data/fastq/sample.fastq.gz --paf results/dorado_correct/sample.paf -o results/dorado_correct

REQUIRED OPTIONS:
-i/--reads          <file>  Input reads in FASTQ format
--paf               <file>  Input alignments in PAF format (from dorado-correct1.sh)
-o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
--index_size        <str>   Amount of memory for indexing, per core           [default: $index_size]
--more_opts         <str>   Quoted string with one or more additional options
                            for $TOOL_NAME

UTILITY OPTIONS:
  -h/--help                 Print this help message
  -v/--version              Print script and $TOOL_NAME versions

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
reads=
paf=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --reads )      check_val "$1" "${2:-}"; shift; reads=$1 ;;
        --paf )             check_val "$1" "${2:-}"; shift; paf=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --index_size )      check_val "$1" "${2:-}"; shift; index_size=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Print version info and exit, if requested
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$reads" ]] && die "No input reads file specified, do so with -i/--reads" "$all_opts"
[[ -z "$paf" ]] && die "No input PAF file specified, do so with --paf" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$reads" ]] && die "Input file $reads does not exist"
[[ ! -f "$paf" ]] && die "Input file $paf does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
outfile="$outdir"/$(basename "${reads%%.*}").fasta

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
echo "Input FASTQ file:                         $reads"
echo "Input PAF file:                           $paf"
echo "Output file:                              $outfile"
echo "Memory size for indexing:                 $index_size"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$reads" "$paf"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" correct \
    --device cuda:all \
    --index-size "$index_size" \
    --from-paf "$paf" \
    --verbose \
    $more_opts \
    "$reads" \
    > "$outfile"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing the output file:"
ls -lh "$outfile"
final_reporting
