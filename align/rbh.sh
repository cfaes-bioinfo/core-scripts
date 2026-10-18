#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=rbh
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Find reciprocal best hits between a query proteome and a donor proteome.

The work is done by rbh.py next to this script; see its header for why a
one-way best hit is not enough, and for what the 'tier' column means.

This script only wires up the two DIAMOND outputs, the logging and the
provenance record."
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=python3
TOOL_NAME=Python
TOOL_DOCS=https://github.com/mcic-osu/mcic-scripts
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=none                       # Standard library only; no container needed
conda_path=
container_url=
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
# Floors on what counts as a hit at all. 30% identity over half the query is the
# conventional lower bound for transferring a name between vertebrates; anything
# looser is a domain match, not an ortholog.
min_pident=30
min_qcov=50
max_evalue=1e-5

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
      sbatch $0 \\
          --forward results/diamond/vs-sprot.tsv \\
          --reverse results/diamond/sprot-vs-query.tsv \\
          --donor swissprot \\
          -o results/rbh/swissprot.tsv

REQUIRED OPTIONS:
  --forward           <file>  DIAMOND output with the query proteome as queries
  --reverse           <file>  DIAMOND output with the donor proteome as queries
  -o/--outfile        <file>  Output TSV (its dir will be created if needed)

OTHER KEY OPTIONS:
  --donor             <str>   Label for the donor, written to the 'donor' column [default: basename of --outfile]
  --min_pident        <num>   Minimum percent identity                           [default: $min_pident]
  --min_qcov          <num>   Minimum percent query coverage                     [default: $min_qcov]
  --max_evalue        <num>   Maximum E-value                                    [default: $max_evalue]

OUTPUT:
  <outfile>   - one row per query that kept a hit, with a 'tier' column
                ('RBH' or 'forward_best')
  Alongside it, '<dir of outfile>/logs' will contain:
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
forward=
reverse=
outfile=
donor=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --forward )          check_val "$1" "${2:-}"; shift; forward=$1 ;;
        --reverse )          check_val "$1" "${2:-}"; shift; reverse=$1 ;;
        -o | --outfile )     check_val "$1" "${2:-}"; shift; outfile=$1 ;;
        --donor )            check_val "$1" "${2:-}"; shift; donor=$1 ;;
        --min_pident )       check_val "$1" "${2:-}"; shift; min_pident=$1 ;;
        --min_qcov )         check_val "$1" "${2:-}"; shift; min_qcov=$1 ;;
        --max_evalue )       check_val "$1" "${2:-}"; shift; max_evalue=$1 ;;
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
# Load the software environment
load_env   # Note: reads the env_type/conda_path/container_* globals, takes no args
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$forward" ]] && die "No forward DIAMOND output specified, do so with --forward" "$all_opts"
[[ -z "$reverse" ]] && die "No reverse DIAMOND output specified, do so with --reverse" "$all_opts"
[[ -z "$outfile" ]] && die "No output file specified, do so with -o/--outfile" "$all_opts"
[[ ! -f "$forward" ]] && die "Forward DIAMOND output $forward does not exist"
[[ ! -f "$reverse" ]] && die "Reverse DIAMOND output $reverse does not exist"

# The Python script that does the work must sit next to this one
rbh_script="$script_dir"/rbh.py
[[ ! -f "$rbh_script" ]] && die "Cannot find $rbh_script - it should sit next to this script"

# Define outputs based on script parameters
outdir=$(dirname "$outfile")
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
[[ -z "$donor" ]] && donor=$(basename "${outfile%.*}")
log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Forward DIAMOND output (query proteome):  $forward"
echo "Reverse DIAMOND output (donor is query):  $reverse"
echo "Output TSV:                               $outfile"
echo "Donor label:                              $donor"
echo "Minimum percent identity:                 $min_pident"
echo "Minimum percent query coverage:           $min_qcov"
echo "Maximum E-value:                          $max_evalue"
log_time "Listing the input files:"
ls -lh "$forward" "$reverse"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Finding reciprocal best hits..."
runstats "$TOOL_BINARY" "$rbh_script" \
    --forward "$forward" \
    --reverse "$reverse" \
    --out "$outfile" \
    --donor "$donor" \
    --min_pident "$min_pident" \
    --min_qcov "$min_qcov" \
    --max_evalue "$max_evalue"

[[ ! -s "$outfile" ]] && die "No output was written to $outfile"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Identity distribution of the RBH pairs:"
awk -F'\t' '$9 == "RBH" { n[int($4 / 10) * 10]++ }
    END { for (b in n) printf "  %3d-%3d%% identity: %8d\n", b, b + 9, n[b] }' \
    "$outfile" | sort -n

log_time "Listing the output file:"
ls -lh "$outfile"
final_reporting   # Note: reads the LOG_DIR global, takes no args
