#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=nf_bactfinder
#SBATCH --output=slurm-nf_bactfinder-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants
DESCRIPTION="Run the BactFinder Nextflow workflow to examine bacterial
genome assemblies with ResFinder, VirulenceFinder and PlasmidFinder"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="nextflow run"
export TOOL_NAME="nextflow"
VERSION_COMMAND="nextflow -v"

# Constants - paramaters
NF_REPO=https://github.com/jelmerp/nf_bactfinder
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
OSC_CONFIG=mcic-scripts/nextflow/osc.config

# Defaults - generics
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow
osc_config=mcic-scripts/nextflow/osc.config  # Will be downloaded if not present here
container_dir=/fs/ess/PAS0471/containers
container_path=
dl_container=false
profile="conda" #profile="standard,singularity"
resume=true && resume_arg="-resume"
slurm_job=$(echo "$SLURM_JOB_ACCOUNT" | tr "[a-z]" "[A-Z]")
work_dir=/fs/scratch/$slurm_job/$USER/nf_bactfinder
version_only=false

# Defaults - parameters
outdir=results/nf_bactfinder

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLES:"
    echo "  sbatch $0 -i results/assemblies --species 'Enterobacter cloacae'"
    echo "  sbatch $0 -i results/assemblies --species 'Salmonella enterica' --file_pattern '*fna'"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir      <dir>   Input directory with assembly nucleotide FASTA files"
    echo "  --species       <str>   Quoted string with focal species name, e.g.: --species 'Enterobacter cloacae'"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  -o/--outdir     <dir>   Output directory for workflow results       [default: 'results/nf_bactfinder']"
    echo "  --file_pattern  <str>   Single-quoted FASTQ file pattern (glob)     [default: '*fasta']"
    echo "  --more_args     <str>   Additional arguments to pass to 'nextflow run'"
    echo "                            - Use any additional option of Nextflow or of the workflow itself"
    echo "                            - Example (quote the entire string!): '--more_args \"--res_cov 0.8\"'"
    echo
    echo "NEXTFLOW-RELATED OPTIONS:"
    echo "  --restart                   Restart workflow from the beginning     [default: resume workflow if possible]"
    echo "  --workflow_dir      <dir>   Dir with/for the workflow repo          [default: $workflow_dir]"
    echo "                                - If the correct workflow is already present in this dir, it won't be downloaded again"
    echo "  --container_dir     <dir>   Directory with container images         [default: $container_dir]"
    echo "                                - Required container images will be downloaded here when not already present"
    echo "  --profile           <str>   'Profile' name from any of the config files to use   [default: 'standard,singularity']"
    echo "  --config            <file>  Additional config file                  [default: none]"
    echo "                                - Settings in this file will override default settings"
    echo "                                - Note that the mcic-scripts OSC config file will always be included"
    echo "                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  --work_dir           <dir>  Scratch (work) dir for the workflow     [default: $work_dir]"
    echo "                                - This is where the workflow results will be stored before final results are copied to the output dir."
    echo "  --version                   Print the version of Nextflow and exit"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo
    echo "DOCUMENTATION:"
    echo "- This script runs a workflow based on the GHRU <https://gitlab.com/cgps/ghru/pipelines/amr_prediction>"
    echo "- ResFinder documentation: https://bitbucket.org/genomicepidemiology/resfinder/src/master/"
    echo
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

nextflow_setup() {
    # Singularity container dir - any downloaded containers will be stored here;
    # if the required container is already there, it won't be re-downloaded
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    mkdir -p "$NXF_SINGULARITY_CACHEDIR"

    # Limit memory for Nextflow main process - see https://www.nextflow.io/blog/2021/5_tips_for_hpc_users.html
    export NXF_OPTS='-Xms1g -Xmx4g'
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
indir=
species=
config_file=
file_pattern= && file_pattern_arg=
more_args=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --species )         shift && species=$1 ;;
        --file_pattern )    shift && file_pattern=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        -work-dir )         shift && work_dir=$1 ;;
        -profile )          shift && profile=$1 ;;
        -config )           shift && config_file=$1 ;;
        --more_args )       shift && more_args=$1 ;;
        -no-resume )        resume=false ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$indir" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$species" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# Get the OSC config file
if [[ ! -f "$osc_config" ]]; then
    wget -q "$OSC_CONFIG_URL"
    osc_config=$(basename "$OSC_CONFIG_URL")
fi

# Build the config option
[[ ! -f "$OSC_CONFIG" ]] && OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_arg="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_arg="$config_arg -c ${config_file/,/ -c }"

# Build other opions
[[ "$resume" == false ]] && resume_arg=
[[ -n "$file_pattern" ]] && file_pattern_arg="--file_pattern $file_pattern"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:    $all_opts"
echo "Input dir:                       $indir"
echo "Output dir:                      $outdir"
echo "Species:                         $species"
[[ -n "$file_pattern" ]] && echo "Input file pattern:              $file_pattern"
echo
echo "Resume previous run:             $resume"
echo "Nextflow workflow file:          $NF_REPO"
echo "Container dir:                   $container_dir"
echo "Scratch (work) dir:              $work_dir"
echo "Config file argument:            $config_arg"
[[ -n "$config_file" ]] && echo "Additional config file:          $config_file"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output directories
log_time "Creating the output directories..."
mkdir -pv "$work_dir" "$container_dir"

# Download the OSC config file
if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi

# Make sure we have the latest version of the workflow
nextflow pull $NF_REPO -r master

# Run the workflow run command
log_time "Starting the workflow...\n"
runstats $TOOL_BINARY "$NF_REPO" \
    --indir "$indir" \
    --outdir "$outdir" \
    --species "$species" \
    $file_pattern_arg \
    -work-dir "$work_dir" \
    -with-report "$LOG_DIR"/report.html \
    -with-trace "$LOG_DIR"/trace.txt \
    -with-timeline "$LOG_DIR"/timeline.html \
    -with-dag "$LOG_DIR"/dag.png \
    -ansi-log false \
    -profile "$profile" \
    $config_arg \
    $resume_arg \
    $more_args

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
