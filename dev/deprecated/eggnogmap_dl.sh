#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=eggnogmap_dl
#SBATCH --output=slurm-eggnogmap_dl-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
readonly DESCRIPTION="Download the EggNOG database in preparation for an EggNOGmapper run"
readonly MODULE=miniconda3/23.3.1-py310
readonly CONDA=/fs/ess/PAS0471/jelmer/conda/eggnogmapper
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
readonly TOOL_BINARY=download_eggnog_data.py
readonly TOOL_NAME=download_eggnog_data.py
readonly TOOL_DOCS=https://github.com/eggnogdb/eggnog-mapper/wiki/eggNOG-mapper-v2.1.5-to-v2.1.11
readonly VERSION_COMMAND="emapper.py --version"

# Constants - parameters
PFAM_ARG="-P"               # Always include the PFAM db
MMSEQS_ARG="-M"             # Always include the MMseqs DB

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo
    echo "        $0 (v. $SCRIPT_VERSION): Run $TOOL_NAME"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage (always submit your scripts to SLURM with 'sbatch'):"
    echo "      sbatch $0 -o data/emapper"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_args     <str>   Quoted string with additional argument(s) for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help               Print this help message and exit"
    echo "  -v                      Print the version of this script and exit"
    echo "  --version               Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
    echo
}

# Function to source the script with Bash functions
source_function_script() {
    local is_slurm=$1

    # Determine the location of this script, and based on that, the function script
    if [[ "$is_slurm" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script=$(realpath "$script_dir"/../dev/bash_functions.sh)
    
    if [[ ! -f "$function_script" ]]; then
        echo "Can't find script with Bash functions ($function_script), downloading from GitHub..."
        git clone https://github.com/mcic-osu/mcic-scripts.git
        function_script=mcic-scripts/dev/bash_functions.sh
    fi
    source "$function_script"
}

# ==============================================================================
#                          INFRASTRUCTURE SETUP I
# ==============================================================================
# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
outdir=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -o | --outdir )     shift && readonly outdir=$1 ;;
        --more_args )       shift && readonly more_args=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         load_env "$MODULE" "$CONDA"
                            print_version "$VERSION_COMMAND" && exit 0 ;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check arguments
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Logging files and dirs
readonly LOG_DIR="$outdir"/logs
readonly VERSION_FILE="$LOG_DIR"/version.txt
readonly CONDA_YML="$LOG_DIR"/conda_env.yml
readonly ENV_FILE="$LOG_DIR"/env.txt
mkdir -p "$LOG_DIR"

# Load software
load_env "$MODULE" "$CONDA" "$CONDA_YML"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options/arguments passed to this script:  $all_args"
echo "Output dir:                                   $outdir"
[[ -n $more_args ]] && echo "Additional arguments for $TOOL_NAME:          $more_args"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Run the tool
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --data_dir "$outdir" \
    $PFAM_ARG \
    $MMSEQS_ARG \
    -y \
    $more_args

# Options used:
#  -y       Assume "yes" to all questions

# Other possible options:
#  -H, -d   for HMMER database

# List the output, report version, etc
echo "Data downloaded on $(date +%F)" > "$outdir"/README.txt
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$VERSION_COMMAND" "$VERSION_FILE" "$ENV_FILE" "$IS_SLURM" \
    "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL"
