#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=kraken_dl
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Download and extract a pre-built Kraken2 (or Bracken) database from a URL
  See https://benlangmead.github.io/aws-indexes/k2 for a list of available databases"
SCRIPT_VERSION="2026-08-22"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=wget
TOOL_NAME=wget
TOOL_DOCS=https://benlangmead.github.io/aws-indexes/k2
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=none            # wget/tar are standard utilities, no Conda env or container needed
container_url=
container_dir="$HOME/containers"
container_path=
conda_path=

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
      sbatch $0 --db-url https://genome-idx.s3.amazonaws.com/kraken/k2_pluspfp_20260626.tar.gz -o results/kraken_db

REQUIRED OPTIONS:
  --db-url            <str>   URL to a Kraken2/Bracken database tarball (.tar.gz)
  -o/--outdir         <dir>   Output dir for the database (will be created if needed)

OUTPUT:
  Alongside the tool's own output, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
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
db_url=
outdir=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db-url )           check_val "$1" "${2:-}"; shift; db_url=$1 ;;
        -o | --outdir )      check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --env_type )         check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )       check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )    check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )    check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )   check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )        script_help; exit 0 ;;
        -v | --version)      version_only=true ;;
        * )                  die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check that this script's TODOs have been filled in
[[ -z "$TOOL_BINARY" ]] && die "TOOL_BINARY has not been set in this script"
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

# Print version info and exit, if requested (this needs the software env loaded)
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$db_url" ]] && die "No database URL specified, do so with --db-url" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"
db_file="$outdir"/"$(basename "$db_url")"

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
echo "Database URL:                             $db_url"
echo "Output dir:                               $outdir"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment - done here rather than earlier so that its
# messages appear after the summary of options above
load_env   # Note: reads the env_type/conda_path/container_* globals, takes no args

log_time "Downloading the Kraken database..."
runstats "$TOOL_BINARY" -O "$db_file" "$db_url"

log_time "Extracting the Kraken database..."
runstats tar -xzf "$db_file" -C "$outdir"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
