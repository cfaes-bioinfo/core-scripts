#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nfc_smrnaseq
#SBATCH --output=slurm-nfc_smrnaseq-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the Nextflow/nf-core small RNA-Seq pipeline 'smrnaseq' (https://nf-co.re/smrnaseq)"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY="nextflow run"
export TOOL_NAME="nextflow"
VERSION_COMMAND="nextflow -v"

# Constants - parameters
WORKFLOW_NAME=nf-core/smrnaseq                              # The name of the nf-core workflow
PROTOCOL=illumina                                           # See https://nf-co.re/smrnaseq/2.4.1/docs/usage/#protocol
PROFILE="singularity,$PROTOCOL"                             # Run workflow with Singularity containers
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config

# Parameter defaults - infrastructure
version_only=false                                          # When true, just print tool & script version info and exit
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow        # Nextflow Conda environment
osc_account=PAS0471                                         # If the scripts is submitted with another project, this will be updated (line below)
[[ -n $SLURM_JOB_ACCOUNT ]] && osc_account=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")

# Parameter defaults - workflow
workflow_version=2.4.1                                      # The version of the nf-core workflow
workflow_dir=                                               # Path to local workflow copy (optional)
resume=true && resume_opt="-resume"
work_dir=/fs/scratch/"$osc_account"/$USER/nfc_smrnaseq      # 'work dir' for initial outputs (note: final outputs go to --outdir instead)
container_dir="$work_dir"/containers

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo -e "
                        $0
    v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL
        ==============================================

DESCRIPTION:
$DESCRIPTION

USAGE / EXAMPLE COMMANDS:
  sbatch $0 -o results/nfc_smrnaseq --fq_dir data/fastq -p config/nfc-smrnaseq.yml

REQUIRED OPTIONS:
  -o/--outdir         <dir>   Dir for final workflow output files
                              (will be created if needed)
  -p/--params         <file>  YAML file with workflow parameters.
                              Use 'mcic-scripts/smrna/nfc-smrnaseq.yml' as
                              a template/starting point

TO POINT TO THE INPUT FASTQ FILES, USE ONE OF THE BELOW TWO OPTIONS:
  -i/--fq_dir         <dir>   Dir with FASTQ files -- assumes
                              single-end Illumina files from a single run
  --samplesheet       <file>  Pre-made CSV samplesheet, see
                              https://nf-co.re/smrnaseq/2.4.1/docs/usage/#samplesheet-input

OTHER OPTIONS:
  --workflow_dir      <dir>   Path to local workflow copy (e.g., software/nf-core-smrnaseq_2.4.1/2_4_1)  [default: use remote version]
                                - When specified, this local copy will be used instead of pulling from nf-core
                                - Useful for testing patched/edited workflows
  --workflow_version  <str>   nf-core smrnaseq workflow version to use          [default: $workflow_version]
  --restart                   Don't attempt to resume workflow: start over      [default: resume workflow]
  --container_dir     <dir>   Directory with container images                   [default: $container_dir]
                                - Required images will be downloaded here when
                                  not already present here
  --config            <file>  Additional config file                            [default: none]
                                - Settings in this file will override default
                                  settings
                                - Note that the mcic-scripts OSC config file
                                  will always be included, too
                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)
  --work_dir           <dir>  Scratch (work) dir for the workflow               [default: $work_dir]
                                - This is where the workflow results will be
                                  stored before final results are copied to
                                  the output dir.
  -h/--help                   Print this help message and exit
  -v/--version                Print versions and exit
"
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
outdir=
params_file=
config_file=
workflow_dir=
revision_opt=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --fq_dir )                 shift && fq_dir=$1 ;;
        --samplesheet )                 shift && samplesheet=$1 ;;
        -p | --params )                 shift && params_file=$1 ;;
        -o | --outdir )                 shift && outdir=$1 ;;
        --workflow_dir )                shift && workflow_dir=$1 ;;
        --workflow_version )            shift && workflow_version=$1 ;;
        --config | -config )            shift && config_file=$1 ;;
        --work_dir | -work )            shift && work_dir=$1 ;;
        --container_dir )               shift && container_dir=$1 ;;
        --restart | -restart )          resume=false && resume_opt= ;;
        -h | --help )                   script_help; exit 0 ;;
        -v | --version )                version_only=true ;;
        * )                             die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# Check arguments
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$params_file" ]] && die "No parameter YAML file specified, do so with -p/--params" "$all_opts"
[[ ! -f "$params_file"  ]] && die "Input parameter YAML file $params_file does not exist"
[[ -z "$fq_dir" && -z "$samplesheet" ]] && die "No input FASTQ dir nor samplesheet specified, specify one of these either with --samplesheet or --fq_dir" "$all_opts"
[[ -n "$fq_dir" && ! -d "$fq_dir"  ]] && die "Input FASTQ file dir $fq_dir does not exist"
[[ -n "$samplesheet" && ! -f "$samplesheet"  ]] && die "Input FASTQ samplesheet file $samplesheet does not exist"
[[ -n "$config_file" && ! -f "$config_file"  ]] && die "Input config file $config_file does not exist"
[[ -n "$workflow_dir" && ! -d "$workflow_dir"  ]] && die "Workflow dir $workflow_dir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$conda_path"
nextflow_setup
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0
set_threads "$IS_SLURM"

# Set workflow to local copy if provided, otherwise use remote
if [[ -n "$workflow_dir" ]]; then
    WORKFLOW_NAME="$(cd "$workflow_dir" && pwd)"  # Use absolute path
else
     revision_opt="-r $workflow_version"
fi

# Build the config argument
OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_opt="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_opt="$config_opt -c ${config_file/,/ -c }"

# Other dirs
LOG_DIR="$outdir"/logs

# Report
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:                 $all_opts"
echo
echo "INPUT AND OUTPUT:"
[[ -n "$samplesheet" ]] && echo "Samplesheet:                                  $samplesheet"
[[ -n "$fq_dir" ]] && echo "Input FASTQ dir:                              $fq_dir"
echo "Parameter YAML file:                          $params_file"
echo "Output dir:                                   $outdir"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
[[ -n "$workflow_dir" ]] && echo "Local workflow dir:                           $WORKFLOW_NAME"
[[ -z "$workflow_dir" ]] && echo "Workflow (remote):                            $WORKFLOW_NAME"
echo "Resume previous run (if any):                 $resume"
echo "Container dir:                                $container_dir"
echo "Scratch (work) dir:                           $work_dir"
echo "Config file argument:                         $config_opt"
[[ -n "$config_file" ]] && echo "Additional config file:                       $config_file"
echo "=========================================================================="
log_time "Printing the contents of the parameter file:"
cat -n "$params_file"
if [[ -n "$config_file" ]]; then
    log_time "Printing the contents of the additional config file:"
    cat -n "$config_file"
fi
echo "=========================================================================="
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
    
    echo "sample,fastq_1" > "$samplesheet"
    ls "$fq_dir"/*_R1_* | sed -E 's@.*/(.*)_S[0-9].*@\1,&@' >> "$samplesheet"

    log_time "Printing the contents of samplesheet $samplesheet:"
    cat "$samplesheet"
fi

# Copy the samplesheet and the parameter YAML file to the output dir for record-keeping
log_time "Copying the samplesheet and parameter YAML file to the output dir..."
cp -v "$samplesheet" "$params_file" "$outdir"/

# Run the tool
log_time "Starting the workflow.."
runstats $TOOL_BINARY $WORKFLOW_NAME \
    $revision_opt \
    -params-file "$params_file" \
    --input "$samplesheet" \
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
