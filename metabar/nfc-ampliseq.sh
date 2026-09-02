#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=72:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nfc_ampliseq
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the Nextflow-core metabarcoding pipeline from https://nf-co.re/ampliseq"
SCRIPT_VERSION="2026-09-02"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="nextflow run"
TOOL_NAME=nextflow
TOOL_DOCS=https://nf-co.re/ampliseq/
VERSION_COMMAND="nextflow -version"

# Constants - parameters
WORKFLOW_NAME=nf-core/ampliseq                              # The name of the nf-core workflow
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config

# Defaults - generic
# NOTE: Nextflow itself is always run from a Conda env, so the template's
#       '--env_type'/'--container_url'/'--container_path' options are omitted
#       here, and '--container_dir' refers to Nextflow's own container cache
env_type=conda
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow
osc_account=PAS0471                                         # If the script is submitted with another project, this will be updated (line below)
[[ -n "${SLURM_JOB_ACCOUNT:-}" ]] && osc_account=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")

# Defaults - workflow
workflow_version=2.18.0                                     # The version of the nf-core workflow
work_dir=/fs/scratch/"$osc_account"/$USER/nfc-ampliseq      # 'work dir' for initial outputs (selected, final outputs go to the outdir)
container_dir="$work_dir"/containers                        # The workflow will download containers to this dir
profile="singularity"
resume=true
resume_opt="-resume"

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
  - Different from the Nextflow default, this script will try to 'resume'
    (rather than restart) a previous incomplete run by default.
  - This workflow can be used for both 16S and ITS data: default is 16S;
    change the settings in nfc-ampliseq.yml for ITS.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -o results/ampliseq -p config/nfc-ampliseq.yml
  - With an extra config file and a specific workflow version:
      sbatch $0 -o results/ampliseq -p config/nfc-ampliseq.yml \
        --config extra.config --workflow_version $workflow_version

REQUIRED OPTIONS:
  -p/--params         <file>  YAML file with workflow parameters. Template:
                              'mcic-scripts/metabar/nfc-ampliseq.yml'
  -o/--outdir         <dir>   Dir for pipeline output files
                              (will be created if needed)

OTHER KEY OPTIONS:
  --workflow_version  <str>   Nf-core ampliseq workflow version to use          [default: $workflow_version]
  --restart                   Don't attempt to resume workflow: start over      [default: resume workflow]

NEXTFLOW OPTIONS:
  --work_dir           <dir>  Scratch (work) dir for the workflow               [default: $work_dir]
                                - This is where workflow results are created
                                  before final results are copied to the output
                                  dir.
  --container_dir     <dir>   Directory with container images                   [default: $container_dir]
                                - Required images will be downloaded here
  --config            <file>  Additional config file(s), comma-separated        [default: none]
                                - Settings in this file will override defaults
                                - Note that the mcic-scripts OSC config file
                                  will always be included, too
                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)
  --profile            <str>  'Profile' to use from one of the config files     [default: $profile]

OUTPUT:
  Alongside the pipeline's own output, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:
  --conda_path        <dir>   Full path to a Nextflow Conda environment to use  [default: $conda_path]
  -h/--help                   Print this help message
  -v/--version                Print script and $TOOL_NAME versions

PIPELINE DOCUMENTATION:
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

nextflow_setup() {
    # Singularity container dir - any downloaded containers will be stored here;
    # if the required container is already there, it won't be re-downloaded
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    mkdir -p "$NXF_SINGULARITY_CACHEDIR"

    # Limit memory for Nextflow main process - see https://www.nextflow.io/blog/2021/5_tips_for_hpc_users.html
    export NXF_OPTS='-Xms1g -Xmx4g'
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
outdir=
params_file=
config_file=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o | --outdir )             check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        -p | --params )             check_val "$1" "${2:-}"; shift; params_file=$1 ;;
        --workflow_version )        check_val "$1" "${2:-}"; shift; workflow_version=$1 ;;
        --container_dir )           check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --config | -config )        check_val "$1" "${2:-}"; shift; config_file=$1 ;;
        --profile | -profile )      check_val "$1" "${2:-}"; shift; profile=$1 ;;
        --work_dir | -work-dir )    check_val "$1" "${2:-}"; shift; work_dir=$1 ;;
        --conda_path )              check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --restart | -restart )      resume=false; resume_opt= ;;
        -h | --help )               script_help; exit 0 ;;
        -v | --version )            version_only=true ;;
        * )                         die "Invalid option $1" "$all_opts" ;;
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

# Print version info and exit, if requested (this needs the software env loaded)
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$params_file" ]] && die "No parameter YAML file specified, do so with -p/--params" "$all_opts"
[[ ! -f "$params_file"  ]] && die "Input parameter YAML file $params_file does not exist"
if [[ -n "$config_file" ]]; then
    for cfg in ${config_file//,/ }; do
        [[ ! -f "$cfg" ]] && die "Additional config file $cfg does not exist"
    done
fi

# Warn if the output dir already holds results from a previous run
# (only when starting over: when resuming, a populated outdir is expected)
[[ "$resume" == false ]] && check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

# Build the config argument
OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_opt="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_opt="$config_opt -c ${config_file//,/ -c }"

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
echo "INPUT AND OUTPUT:"
echo "Parameter YAML file:                      $params_file"
echo "Output dir:                               $outdir"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Workflow version:                         $workflow_version"
echo "Resume previous run (if any):             $resume"
echo "Container dir:                            $container_dir"
echo "Scratch (work) dir:                       $work_dir"
echo "Config 'profile':                         $profile"
echo "Config file argument:                     $config_opt"
[[ -n "$config_file" ]] && echo "Additional config file(s):                $config_file"
log_time "Listing the input file(s):"
ls -lh "$params_file"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources
echo "=========================================================================="
log_time "Printing the contents of the parameter file:"
cat -n "$params_file"
if [[ -n "$config_file" ]]; then
    log_time "Printing the contents of the additional config file(s):"
    cat -n ${config_file//,/ }
fi
echo "=========================================================================="

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# Set up Nextflow (container cache dir and memory for the main process)
nextflow_setup

# Make necessary dirs
log_time "Creating the work and output dirs..."
mkdir -pv "$work_dir" "$outdir"

# Download the OSC config file
if [[ ! -s "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL" ||
        die "Failed to download the OSC config file from $OSC_CONFIG_URL"
fi

# Modify the config file so it has the correct OSC project/account
if [[ "$osc_account" != "PAS0471" ]]; then
    sed -i "s/--account=PAS0471/--account=$osc_account/" "$OSC_CONFIG"
fi

# Run the workflow
log_time "Starting the workflow.."
runstats $TOOL_BINARY $WORKFLOW_NAME \
    -r "$workflow_version" \
    -params-file "$params_file" \
    --outdir "$outdir" \
    -work-dir "$work_dir" \
    -profile "$profile" \
    -ansi-log false \
    $config_opt \
    $resume_opt

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
