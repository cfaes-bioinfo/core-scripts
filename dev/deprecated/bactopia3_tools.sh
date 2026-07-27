#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bactopia3_tools
#SBATCH --output=slurm-bactopia3_tools-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Bactopia v3 tools for follow-up analyses to the main Bactopia workflow"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=bactopia
TOOL_NAME="Bactopia Tools"
TOOL_DOCS=https://bactopia.github.io/
VERSION_COMMAND="bactopia --version"

# Constants - Nextflow and Bactopia generic settings
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
OSC_CONFIG=mcic-scripts/nextflow/osc.config     # Will be downloaded if not present here
QUEUE_SIZE=100                                  # Nr of jobs to be submitted at once
MAX_TIME=1440                                   # In minutes
MAX_MEM=128                                     # In GB
MAX_CPUS=48
MAX_RETRY=1                                     # Retry failed jobs just once

# Defaults - Nextflow generics
work_dir_default=/fs/scratch/$SLURM_JOB_ACCOUNT/$USER/bactopia
container_dir=/fs/ess/PAS0471/containers
profile=singularity
resume=true && resume_opt="-resume"

# Defaults - other generics
env_type=conda                                       # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/bactopia3
version_only=false                              # When true, just print tool & script version info and exit

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/bactopia -o results/bactopia/tools --tool pangenome --more_opts '--use_roary'"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--bactopia_dir   <dir>   Top-level dir with previous Bactopia results"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  --tool              <str>   Bactopia tool to run (see https://bactopia.github.io/latest/bactopia-tools)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --include           <file>  Text file with list of sample IDs to include                    [default: include all]"
    echo "  --exclude           <file>  Text file with list of sample IDs to exclude                    [default: exclude none]"
    echo "  --run_name          <str>   Run name                                                        [default: ${tool}_run]"
    echo "  --restart                   Don't attempt to resume workflow run, but always start over     [default: resume any previous run]"
    echo "  --more_opts         <str>   Additional arguments to pass to the tool"
    echo 
    echo "GENERAL NEXTFLOW OPTIONS:"
    echo "  --work_dir          <dir>   Dir for initial workflow output files                           [default: /fs/scratch/$SLURM_JOB_ACCOUNT/$USER/bactopia]"
    echo "  --config            <file>  Additional Nextflow config file                                 [default: none - but mcic-scripts OSC config will be used]"
    echo "                                - Settings in this file will override default settings"
    echo "                                - Note that the mcic-scripts OSC config file will always be included, too"
    echo "                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  --container_dir     <dir>   Directory with/for stored container images                      [default: $container_dir]"
    echo "  --profile           <str>   Nextflow 'profile' to use from one of the config files          [default: 'singularity']"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION:"
    echo "  - $TOOL_DOCS"
    echo
}

# Function to source the script with Bash functions
source_function_script() {
    # Determine the location of this script, and based on that, the function script
    if [[ "$IS_SLURM" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script=$(realpath "$script_dir"/../dev/"$(basename "$FUNCTION_SCRIPT_URL")")
    # Download the function script if needed, then source it
    if [[ ! -f "$function_script" ]]; then
        echo "Can't find script with Bash functions ($function_script), downloading from GitHub..."
        function_script=$(basename "$FUNCTION_SCRIPT_URL")
        wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script"
    fi
    source "$function_script"
}

nextflow_env() {
    # Singularity container dir - any downloaded containers will be stored here;
    # if the required container is already there, it won't be re-downloaded
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    mkdir -p "$NXF_SINGULARITY_CACHEDIR"
    # Limit memory for Nextflow main process - see https://www.nextflow.io/blog/2021/5_tips_for_hpc_users.html
    export NXF_OPTS='-Xms1g -Xmx4g'
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
indir=
outdir=
tool=
config_file=
work_dir=
run_name=
include= && include_opt=
exclude= && exclude_opt=
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --bactopia_dir )   shift && indir=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --tool )                shift && tool=$1 ;;
        --container_dir )       shift && container_dir=$1 ;;
        --include )             shift && include=$1 ;;
        --exclude )             shift && exclude=$1 ;;
        --run_name )            shift && run_name=$1 ;;
        --more_opts )           shift && more_opts=$1 ;;
        --config )              shift && config_file=$1 ;;
        --profile )             shift && profile=$1 ;;
        --work_dir )            shift && work_dir=$1 ;;
        --restart )             resume=false && resume_opt= ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version )             load_env "$MODULE" "$CONDA"
                                print_version "$VERSION_COMMAND" && exit 0 ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# Check arguments
[[ -z "$indir" ]] && die "No input dir specified, do so with -i/--bactopia_dir" "$all_opts"
[[ -z "$tool" ]] && die "No Bactopia tool specified, do so with --tool" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"
[[ -n "$include" && ! -f "$include" ]] && die "File with samples to include $include does not exist"
[[ -n "$exclude" && ! -f "$exclude" ]] && die "File with samples to exclude $exclude does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict bash settings
set -euo pipefail

# Outputs - make paths absolute
[[ ! "$indir" =~ ^/ ]] && indir=$(realpath "$indir")
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"
[[ ! "$OSC_CONFIG" =~ ^/ ]] && OSC_CONFIG="$PWD"/"$OSC_CONFIG"

# Logging files and dirs
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# Load software
load_env "$conda_path"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0
nextflow_env

# Get the OSC config file, then build the config argument
[[ ! -f "$OSC_CONFIG" ]] && OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_opt="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_opt="$config_opt -c ${config_file/,/ -c }"

# Set Nextflow 'work' dir
if [[ -z "$work_dir" && "$IS_SLURM" == true ]]; then
    work_dir="${work_dir_default/pas/PAS}"  # 'pas' is in lowercase otherwise! 
else
    work_dir="$outdir"/work
fi

# Define outputs
[[ -z "$run_name" ]] && run_name=$(basename "$outdir")
[[ "$run_name" == "$tool" ]] && run_name="$tool"_run  # Run name can't be same as tool name, gives problems
[[ -n "$include" ]] && include_opt="--include $include"
[[ -n "$exclude" ]] && exclude_opt="--exclude $exclude"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:             $all_opts"
echo
echo "Input Bactopia dir:                       $indir"
echo "Output dir:                               $outdir"
[[ -n "$include" ]] && echo "File with samples to include:              $include"
[[ -n "$exclude" ]] && echo "File with samples to exclude:              $exclude"
[[ -n "$more_opts" ]] && echo "More options for Bactopia:                $more_opts"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Resume previous run (if any):             $resume"
echo "Container dir:                            $container_dir"
echo "Scratch ('work') dir:                     $work_dir"
echo "Config 'profile':                         $profile"
echo "Config file argument:                     $config_opt"
[[ -n "$config_file" ]] && echo "Additional config file:                       $config_file"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Download the OSC config file
if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi

# Run Bactopia Tools
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY --wf "$tool" \
    --bactopia "$indir" \
    --outdir "$outdir" \
    --run_name "$run_name" \
    $include_opt \
    $exclude_opt \
    --singularity_cache "$container_dir" \
    --max_cpus $MAX_CPUS \
    --max_time $MAX_TIME \
    --max_memory $MAX_MEM \
    --max_retry $MAX_RETRY \
    -qs $QUEUE_SIZE \
    -w "$work_dir" \
    -profile "$profile" \
    $resume_opt \
    $config_opt \
    -ansi-log false \
    $more_opts

# List the output
final_reporting "$LOG_DIR"
