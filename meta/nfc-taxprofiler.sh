#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --mem=16G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nfc_taxprof
#SBATCH --output=slurm-nfc_taxprof-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the Nextflow/nf-core metagenomic taxonomic profiling pipeline 'taxprofiler' (https://nf-co.re/taxprofiler)"
SCRIPT_VERSION="2026-09-02"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY="nextflow run"
export TOOL_NAME="nextflow"
VERSION_COMMAND="nextflow -v"

# Constants - parameters
WORKFLOW_NAME=nf-core/taxprofiler                           # The name of the nf-core workflow
PROFILE="singularity"                                       # Run workflow with Singularity containers
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config

# Parameter defaults - infrastructure
version_only=false                                          # When true, just print tool & script version info and exit
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow
osc_account=PAS0471                                         # If the scripts is submitted with another project, this will be updated (line below)
[[ -n $SLURM_JOB_ACCOUNT ]] && osc_account=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")

# Parameter defaults - workflow
workflow_version=1.2.2                                      # The version of the nf-core workflow #! Check if up-to-date
work_dir=/fs/scratch/"$osc_account"/$USER/nfc_taxprof       # 'work dir' for initial outputs (note: final outputs go to --outdir instead)
resume=true && resume_opt="-resume"

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
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  sbatch $0 -o results/nfc_taxprof -p config/nfcore_taxprof_params.yml"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -o/--outdir         <dir>   Dir for workflow output files (will be created if needed)"
    echo "  --databases         <file>  CSV file with database info"
    echo "                                - CSV file info: https://nf-co.re/taxprofiler/docs/usage/#full-database-sheet"
    echo "                                - Database building info: https://nf-co.re/taxprofiler/1.2.2/docs/usage/usage/tutorials#retrieving-databases-or-building-custom-databases"
    echo "  -p/--params         <file>  YAML file with workflow parameters"
    echo "                              Use 'mcic-scripts/metabar/nfcore_taxprofiler_params.yml' as a template/starting point"
    echo 
    echo "TO POINT TO THE INPUT FASTQ FILES, USE ONE OF THE BELOW TWO OPTIONS:"
    echo "  --fq_dir            <dir>   Dir with FASTQ files -- assumes paired-end Illumina files, all from a single run"
    echo "                                When you use this option, the script will attempt to create a samplesheet for you"
    echo "  --samplesheet       <file>  Pre-made CSV samplesheet, see https://nf-co.re/taxprofiler/docs/usage/#samplesheet-inputs"
    echo
    echo "OTHER OPTIONS:"
    echo "  --workflow_version  <str>   Workflow version to use                                     [default: $workflow_version]"
    echo "  --restart                   Don't attempt to resume workflow run, but start over        [default: resume workflow]"
    echo "  --container_dir     <dir>   Directory with container images                             [default: $container_dir]"
    echo "                                - Required images will be downloaded here when not already present here" 
    echo "  --config            <file>  Additional config file                                      [default: none]"
    echo "                                - Settings in this file will override default settings"
    echo "                                - Note that the mcic-scripts OSC config file will always be included, too"
    echo "                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  --work_dir           <dir>  Scratch (work) dir for the workflow                         [default: $work_dir]"
    echo "                                - This is where the workflow results will be stored before final results are copied to the output dir."
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of Nextflow and exit"
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
fq_dir=
samplesheet=
db_file=
outdir=
params_file=
config_file=
container_dir=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --fq_dir )                      shift && fq_dir=$1 ;;
        --samplesheet )                 shift && samplesheet=$1 ;;
        --databases )                   shift && db_file=$1 ;;
        -p | --params )                 shift && params_file=$1 ;;
        -o | --outdir )                 shift && outdir=$1 ;;
        --workflow_version )            shift && workflow_version=$1 ;;
        --config | -config )            shift && config_file=$1 ;;
        --work_dir | -work-dir )        shift && work_dir=$1 ;;
        --container_dir )               shift && container_dir=$1 ;;
        --restart | -restart )          resume=false && resume_opt= ;;
        -h | --help )                   script_help; exit 0 ;;
        -v | --version )                     version_only=true ;;
        * )                             die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# Check arguments
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$params_file" ]] && die "No parameter YAML file specified, do so with -p/--params" "$all_opts"
[[ ! -f "$params_file"  ]] && die "Input parameter YAML file $params_file does not exist"
[[ -z "$db_file" ]] && die "No database file specified, do so with --databases" "$all_opts"
[[ ! -f "$db_file"  ]] && die "Database file $db_file does not exist"
[[ -z "$fq_dir" && -z "$samplesheet" ]] && die "No input FASTQ dir nor samplesheet specified, specify one of these either with --samplesheet or --fq_dir" "$all_opts"
[[ -n "$fq_dir" && ! -d "$fq_dir"  ]] && die "Input FASTQ file dir $fq_dir does not exist"
[[ -n "$samplesheet" && ! -f "$samplesheet"  ]] && die "Input FASTQ samplesheet file $samplesheet does not exist"
[[ -n "$config_file" && ! -f "$config_file"  ]] && die "Input config file $config_file does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Build the config argument
OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_opt="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_opt="$config_opt -c ${config_file/,/ -c }"

# Other dirs
[[ -z "$container_dir" ]] && container_dir="$work_dir"/containers
LOG_DIR="$outdir"/logs

# Report
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:                 $all_opts"
echo
echo "INPUT AND OUTPUT:"
[[ -n "$samplesheet" ]] && echo "Samplesheet:                                  $samplesheet"
[[ -n "$fq_dir" ]] && echo "Input FASTQ dir:                              $fq_dir"
echo "Databases file:                               $db_file"
echo "Parameter YAML file:                          $params_file"
echo "Output dir:                                   $outdir"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Resume previous run (if any):                 $resume"
echo "Container dir:                                $container_dir"
echo "Scratch (work) dir:                           $work_dir"
echo "Config file argument:                         $config_opt"
[[ -n "$config_file" ]] && echo "Additional config file:                       $config_file"
echo "=========================================================================="

# Load software and set nr of threads
load_env "$conda_path"
nextflow_setup
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0
set_threads "$IS_SLURM"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Make necessary dirs
log_time "Creating the output directories..."
mkdir -pv "$work_dir" "$container_dir" "$LOG_DIR"

# Download the OSC config file
if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi

# Modify the config file so it has the correct OSC project/account
if [[ "$osc_account" != "PAS0471" ]]; then
    sed -i "s/--account=PAS0471/--account=$osc_account/" "$OSC_CONFIG"
fi

# Create the samplesheet
if [[ -z "$samplesheet" ]]; then
    samplesheet="$outdir"/samplesheet.csv
    log_time "Creating a samplesheet for the pipeline ($samplesheet)..."
    
    echo "sample,run_accession,instrument_platform,fastq_1,fastq_2,fasta" > "$samplesheet"
    ls "$fq_dir"/* | paste -d, - - |
        sed -E -e 's/$/,/' -e 's@.*/(.*)_R?1[._]@\1,run1,ILLUMINA,&@' |
        sed -E 's/_L00[0-9],/,/' | sed -E 's/_S[0-9]+,/,/' \
        >> "$samplesheet"

    log_time "Printing the contents of samplesheet $samplesheet:"
    cat "$samplesheet"
fi

# Run the tool
log_time "Starting the workflow.."
runstats $TOOL_BINARY $WORKFLOW_NAME \
    -r "$workflow_version" \
    -params-file "$params_file" \
    --input "$samplesheet" \
    --databases "$db_file" \
    --outdir "$outdir" \
    -work-dir "$work_dir" \
    -ansi-log false \
    -profile "$PROFILE" \
    $config_opt \
    $resume_opt

# List the output, report version, etc
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
