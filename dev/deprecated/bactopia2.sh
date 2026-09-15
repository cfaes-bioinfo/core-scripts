#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=bactopia
#SBATCH --output=slurm-bactopia-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the Bactopia workflow (up to version 2, there's a separate script for version 3)"
MODULE=miniconda3/4.12.0-py39
CONDA=/fs/ess/PAS0471/jelmer/conda/bactopia
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY=bactopia
TOOL_NAME=Bactopia
TOOL_DOCS=https://bactopia.github.io/
VERSION_COMMAND=
HELP_COMMAND=

# Constants - parameters and settings
# NOTE: The '--cleanup_workdir' option is hardcoded below
# NOTE: The script will always use or download Bactopia datasets
GENOME_LIMIT=100                                # Download max. 100 genomes from the genus of the focal species

QUEUE_SIZE=100                                  # Nr of jobs to be submitted at once
MAX_CPUS=48
MAX_TIME=1440                                   # In hours
MAX_MEMORY=128                                  # In GB

# Parameter defaults
db_dir=data/bactopia                            # Output of the 'bactopia datasets command'
always_download_db=false                        # Default is to only download if $db_dir doesn't exist
container_dir=/fs/ess/PAS0471/containers
profile=singularity
resume=true && resume_arg="-resume"

# URL to OSC Nextflow config file
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
osc_config=mcic-scripts/nextflow/osc.config  # Will be downloaded if not present here

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
    echo "  - Basic usage:"
    echo "      sbatch $0 -i data/fastq/ --species 'Salmonella enterica' -o results/bactopia"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <dir>   Input dir with FASTQ files"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  --species           <str>   Focal species, e.g. 'Salmonella enterica' (make sure to quote!)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --db_dir            <dir>   Dir for downloaded Bactopia datasets (database) data            [default: data/bactopia]"
    echo "  --download_db               Always download datasets, even if --db_dir exists               [default: only download if dir doesn't exist]"
    echo "  --more_args         <str>   Quoted string with additional argument(s) for $TOOL_NAME"
    echo "  --more_args_db      <str>   Quoted string with additional argument(s) for $TOOL_NAME datasets"
    echo "  --restart                   Don't attempt to resume workflow run, but start over            [default: resume]"
    echo 
    echo "UTILITY OPTIONS:"
    echo "  --config            <file>  Additional Nextflow config file                                 [default: none]"
    echo "                                - Settings in this file will override default settings"
    echo "                                - Note that the mcic-scripts OSC config file will always be included, too"
    echo "                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  --profile           <str>   'Profile' to use from one of the config files                   [default: 'singularity']"
    echo "  -h                          Print this help message and exit"
    echo "  --help                      Print the help for $TOOL_NAME and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION:"
    echo "  - $TOOL_DOCS"
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
species=
extra_config_file=
more_args=
more_args_db=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )          shift && indir=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --species )             shift && species=$1 ;;
        --db_dir )              shift && db_dir=$1 ;;
        --download_db )         always_download_db=true ;;
        --more_args )           shift && more_args=$1 ;;
        --more_args_db )        shift && more_args_db=$1 ;;
        --config )              shift && extra_config_file=$1 ;;
        --profile )             shift && profile=$1 ;;
        --restart )             resume=false ;;
        -h )                    script_help; exit 0 ;;
        -v | --version )             load_env "$MODULE" "$CONDA"
                                print_version "$VERSION_COMMAND" && exit 0 ;;
        --help )                load_env "$MODULE" "$CONDA"
                                tool_help "$HELP_COMMAND" && exit 0;;
        * )                     die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check arguments
[[ -z "$indir" ]] && die "No input dir specified, do so with -i/--indir" "$all_args"
[[ -z "$species" ]] && die "No species specified, do so with --species" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict bash settings
set -euo pipefail

# Outputs - absolute paths
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"
[[ ! "$db_dir" =~ ^/ ]] && db_dir="$PWD"/"$db_dir"
[[ ! "$osc_config" =~ ^/ ]] && osc_config="$PWD"/"$osc_config"
samplesheet="$outdir"/samplesheet.tsv
outdir_base=$(dirname "$outdir")
run_name=$(basename "$outdir")

# Get the OSC config file
if [[ ! -f "$osc_config" ]]; then
    wget -q "$OSC_CONFIG_URL"
    osc_config=$(basename "$OSC_CONFIG_URL")
fi

# Build the config argument
config_arg="-c $osc_config"
if [[ -n "$extra_config_file" ]]; then
    [[ ! "$extra_config_file" =~ ^/ ]] && extra_config_file="$PWD"/"$extra_config_file"
    config_arg="$config_arg -c ${extra_config_file/,/ -c }"
fi

# Other
[[ "$resume" == false ]] && resume_arg=

# Logging files and dirs
LOG_DIR="$outdir"/logs
VERSION_FILE="$LOG_DIR"/version.txt
CONDA_YML="$LOG_DIR"/conda_env.yml
ENV_FILE="$LOG_DIR"/env.txt
mkdir -p "$LOG_DIR"

# Load software
load_env "$MODULE" "$CONDA" "$CONDA_YML"
nextflow_env
set_threads "$IS_SLURM"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:             $all_args"
echo "Input dir:                                $indir"
echo "Output dir:                               $outdir"
echo "Species:                                  $species"
echo "Db/Datasets dir:                          $db_dir"
echo "Nr of FASTQ files in the input dir:       $(ls "$indir"/*fastq.gz | wc -l)"
echo "Resume a previous run:                    $resume"
echo "Nextflow config file argument:            $config_arg"
echo "Nextflow profile:                         $profile"
[[ -n $more_args ]] && echo "Other arguments for $TOOL_NAME:   $more_args"
[[ -n $more_args_db ]] && echo "Other arguments for $TOOL_NAME datasets:  $more_args_db"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Prepare the samplesheet
log_time "Preparing the samplesheet $samplesheet with 'bactopia prepare'..."
bactopia prepare "$indir" > "$samplesheet"
log_time "Printing the contents of the sample sheet:"
cat -n "$samplesheet"

# Download datasets
if [[ ! -d "$db_dir" || "$always_download_db" == true ]]; then
    log_time "Downloading Bactopia datasets for $species..."
    runstats $TOOL_BINARY datasets \
        --outdir "$db_dir" \
        --species "$species" \
        --include_genus \
        --limit "$GENOME_LIMIT" \
        --cpus "$threads" \
        --force \
        $more_args_db
fi

# Move into output dir
log_time "Changing into dir $outdir_base..."
cd "$outdir_base" || exit 1

# Removing old trace and log files
#trace_file=$run_name/nf-reports/bactopia-trace.txt
#dag_file=$run_name/nf-reports/bactopia-dag.svg
#report_file=$run_name/nf-reports/bactopia-report.html
#timeline_file=$run_name/nf-reports/bactopia-timeline.html
#rm -vf "$timeline_file" "$report_file" "$dag_file" "$trace_file"

# Run Bactopia
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --samples "$samplesheet" \
    --outdir ./ \
    --run_name "$run_name" \
    -profile "$profile" \
    --species "$species" \
    --datasets "$db_dir" \
    --cleanup_workdir \
    --max_cpus $MAX_CPUS \
    --max_time $MAX_TIME \
    --max_memory $MAX_MEMORY \
    -qs $QUEUE_SIZE \
    --singularity_cache "$container_dir" \
    $resume_arg \
    $config_arg \
    $more_args

#--force \

# List the output
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*

# ==============================================================================
#                               WRAP UP
# ==============================================================================
printf "\n======================================================================"
log_time "Versions used:"
print_version "$VERSION_COMMAND" | tee "$VERSION_FILE"
script_version "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL" | tee -a "$VERSION_FILE" 
env | sort > "$ENV_FILE"
[[ "$IS_SLURM" = true ]] && resource_usage
log_time "Done with script $SCRIPT_NAME\n"
