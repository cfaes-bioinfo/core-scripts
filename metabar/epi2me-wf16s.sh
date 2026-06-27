#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=epi2me-wf16
#SBATCH --output=slurm-epi2me-wf16s-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the ONT-EPI2ME wf-16s pipeline to classify 16S or ITS rRNA gene sequences from ONT"
SCRIPT_VERSION="2026-05-02"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="nextflow run epi2me-labs/wf-16s"
TOOL_NAME="EPI2ME wf-16s"
TOOL_DOCS=https://github.com/epi2me-labs/wf-16s
VERSION_COMMAND="$TOOL_BINARY --version"

# Constants - parameters
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
THREADS_OPT=10  # Not clear if this makes a difference, but it's a direct option of the workflow

# Defaults - generics
conda_path=/fs/ess/PAS0471/conda/nextflow-25.10.2
osc_account=PAS0471                                         # If the script is submitted with another project, this will be updated (line below)
[[ -n $SLURM_JOB_ACCOUNT ]] && osc_account=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")

# Defaults - general Nextflow parameters
work_dir=/fs/scratch/"$osc_account"/$USER/epi2me-wf16s      # 'work dir' for initial outputs (selected, final outputs go to the outdir)
profile="singularity"
resume=true && resume_opt="-resume"
container_dir="$work_dir"/containers                        # The workflow will download containers to this dir

# Defaults - workflow parameters
workflow_version="v1.6.1"  # Default version
classifier=minimap2                                         # Same as workflow default
database=ncbi_16s_18s                                       # Same as workflow default
restructure_indir=false

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
      sbatch $0 -p mcic-scripts/metabar/epi2me-wf16s.yml -o results/epi2me
    
REQUIRED OPTIONS:
  --infile            <file>  Input FASTQ file (use EITHER this OR --indir)
  --indir             <dir>   Input directory with FASTQ files
                              (use EITHER this OR --infile)
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --classifier        <str>   Classifier to use: 'minimap2' or 'kraken2'        [default: $classifier]
  --database          <str>   Database to use: 'ncbi_16s_18s',
                              'ncbi_16s_18s_28s_ITS', or 'SILVA_138_1'          [default: $database]
  -p/--params_file    <file>  YAML file with additional workflow parameters.
                              Template:
                              'mcic-scripts/metabar/epi2me-wf16s.yml'
  --restructure_indir         Using this option will restructure the input dir
                              into per-sample subdirs (true/false).
                              This is necessary if the dir contains files for
                              multiple different samples.                       [default: false]
                              See <https://github.com/epi2me-labs/wf-16s?tab=readme-ov-file#input-example>
                              For this to work, files must have extension
                              '.fastq.gz' and the rest of the file name
                              will be used as sample name.
  --version_workflow  <str>   Workflow version/revision to use                  [default: $workflow_version]

GENERAL NEXTFLOW OPTIONS:
  --restart                   Don't attempt to resume workflow: start over      [default: resume workflow]
  --work_dir           <dir>  Scratch (work) dir for the workflow               [default: $work_dir]
                                - This is where workflow results are created
                                  before final results are copied to the output
                                  dir.
  --container_dir     <dir>   Directory with container images                   [default: $container_dir]
                                - Required images will be downloaded here
  --config            <file>  Additional config file                            [default: none]
                                - Settings in this file will override defaults
                                - Note that the mcic-scripts OSC config file will
                                  always be included, too
                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)
  --profile            <str>  'Profile' to use from one of the config files     [default: $profile]

UTILITY OPTIONS:
  --conda_path        <dir>   Full path to a Conda environment to use           [default (if any): $conda_path]
  -h/--help                   Print this help message
  -v/--version                Print script and $TOOL_NAME versions
    
TOOL DOCUMENTATION:
  $TOOL_DOCS
"
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
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -f "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -f "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script_name"
        fi
        source "$function_script_name"
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
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false  # When true, just print tool & script version info and exit
infile=
indir=
input_opt=
params_file= && params_opt=
config_file=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -o | --outdir )                 shift && outdir=$1 ;;
        --infile )                      shift && infile=$1 ;;
        --indir )                       shift && indir=$1 ;;
        --classifier )                  shift && classifier=$1 ;;
        --database )                    shift && database=$1 ;;
        --restructure_indir )           restructure_indir=true ;;
        --version_workflow )            shift && workflow_version=$1 ;;
        -p | --params_file )            shift && params_file=$1 ;;
        --container_dir )               shift && container_dir=$1 ;;
        --config | -config )            shift && config_file=$1 ;;
        --profile | -profile )          shift && profile=$1 ;;
        --work_dir | -work-dir )        shift && work_dir=$1 ;;
        --restart | -restart )          resume=false && resume_opt= ;;
        --conda_path )                  shift && conda_path=$1 ;;
        -h | --help )                   script_help; exit 0 ;;
        -v | --version)                 version_only=true ;;
        * )                             die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$conda_path"
nextflow_setup
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -n "$params_file" && ! -f "$params_file"  ]] && die "Input parameter YAML file $params_file does not exist"
[[ -n "$infile" ]] && [[ -n "$indir" ]] && die "Provide either --infile or --indir, not both" "$all_opts"

# Build the config argument
OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_opt="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_opt="$config_opt -c ${config_file/,/ -c }"

# Params file option
[[ -n "$params_file" ]] && params_opt="-params-file $params_file"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:             $all_opts"
echo
echo "INPUT AND OUTPUT:"
[[ -n "$infile" ]] && echo "Input file:                               $infile"
[[ -n "$indir" ]] && echo "Input dir:                                $indir"
echo "Output dir:                               $outdir"
echo "Classifier:                               $classifier"
echo "Database:                                 $database"
echo "Restructure input dir:                    $restructure_indir"
[[ -n "$config_file" ]] && echo "Parameter YAML file:                      $params_file"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Resume previous run (if any):             $resume"
echo "Container dir:                            $container_dir"
echo "Scratch (work) dir:                       $work_dir"
echo "Config 'profile':                         $profile"
echo "Config file argument:                     $config_opt"
[[ -n "$config_file" ]] && echo "Additional config file:             $config_file"
echo "=========================================================================="
[[ "$IS_SLURM" = true ]] && slurm_resources
echo "=========================================================================="
log_time "Printing the contents of the parameter file:"
cat -n "$params_file"
if [[ -n "$config_file" ]]; then
    log_time "Printing the contents of the additional config file:"
    cat -n "$config_file"
fi
echo "=========================================================================="

# ==============================================================================
#                               RUN
# ==============================================================================
# Make necessary dirs
log_time "Creating the output directories..."
mkdir -pv "$work_dir" "$container_dir" "$outdir"/logs

# Build the input option
[[ -n "$infile" ]] && input_opt="--fastq $infile"

if [[ -n "$indir" ]]; then
    if [[ "$restructure_indir" == true ]]; then
        log_time "Restructuring input dir $indir into per-sample subdirs..."
        indir_restruct="$outdir"/input_restructured && mkdir -p "$indir_restruct"
        
        for fq in "$indir"/*fastq.gz; do
            barcode=$(basename "$fq" .fastq.gz)
            mkdir -p "$indir_restruct"/"$barcode"
            ln -sf "$(realpath "$fq")" "$indir_restruct"/"$barcode"/"$barcode".fastq.gz
        done
        
        indir="$indir_restruct"
    fi
    input_opt="--fastq $indir"
fi
log_time "Listing the input files:"
[[ -n "$infile" ]] && ls -lh "$infile"
[[ -n "$indir" ]] && tree "$indir"

# Download the OSC config file
if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi

# Modify the config file so it has the correct OSC project/account
if [[ "$osc_account" != "PAS0471" ]]; then
    sed -i "s/--account=PAS0471/--account=$osc_account/" "$OSC_CONFIG"
fi

# Run the workflow
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -r "$workflow_version" \
    $input_opt \
    --out_dir "$outdir" \
    --classifier "$classifier" \
    --database_set "$database" \
    $params_opt \
    --threads "$THREADS_OPT" \
    -work-dir "$work_dir" \
    -profile "$profile" \
    -ansi-log false \
    $config_opt \
    $resume_opt

# Move the 'store_dir' dir from the current working dir to the outdir
[[ -d store_dir ]] && mv store_dir "$outdir"/

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
