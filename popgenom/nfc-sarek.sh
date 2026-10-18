#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=72:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nfc_sarek
#SBATCH --output=slurm-nfc_sarek-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the Nextflow/nf-core Sarek pipeline (https://nf-co.re/sarek) for genomic variant calling"
SCRIPT_VERSION="2026-09-02"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="nextflow run"
export TOOL_NAME="Nextflow"
VERSION_COMMAND="nextflow -v"

# Constants - specific
WORKFLOW_NAME=nf-core/sarek                            # The name of the nf-core workflow
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config # Nextflow <=> OSC config file
TOOL_DOCS=https://nf-co.re/sarek

# Defaults - pipeline parameters
workflow_version=3.8.1                                 # The version of the nf-core workflow
resume=true && resume_arg="-resume"                    # Resume the workflow from wherever it left off

# Defaults - generics
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow
osc_account=PAS0471
[[ -n $SLURM_JOB_ACCOUNT ]] && osc_account=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")
work_dir=/fs/scratch/"$osc_account"/$USER/nfc-sarek    # 'work dir' for initial outputs (selected, final outputs go to the outdir)
profile="singularity"                                  # 'singularity' to have the workflow use containers (alternatively, 'conda')

# ==============================================================================
#                                FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "
                        $0
    v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)
            =================================================

DESCRIPTION:
$DESCRIPTION
    
USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 --samplesheet metadata/samplesheet.csv --ref_fasta data/assembly.fna -o results/sarek
    
REQUIRED OPTIONS:
  --ref_fasta         <file>  Reference genome FASTA file
  -o/--outdir         <dir>   Output dir (will be created if needed)
  -p/--params         <file>  YAML file with workflow parameters. As a template,
                              use 'mcic-scripts/popgenom/nfcore_sarek_params.yml'

TO SPECIFY INPUT FASTQ FILES, USE ONE OF THE FOLLOWING TWO OPTIONS:
  --samplesheet       <file>  Input samplesheet CSV file (see https://nf-co.re/sarek/usage)
  --fq_dir            <dir>   Dir with FASTQ files. When provided, this shell
                              script will attempt to make a samplesheet.

OTHER KEY OPTIONS:
  --workflow_version  <str>   Nf-core sarek workflow version                    [default: $workflow_version]
  --restart                   Restart nf-core workflow from the beginning       [default: resume if possible]

ADVANCED NEXTFLOW-RELATED OPTIONS:
  --work_dir           <dir>  Scratch (work) dir for the workflow               [default: $work_dir]
                              This is where all workflow results are stored
                              before final results are copied to the output dir.
  --container_dir     <dir>   Directory with container images                   [default: $container_dir]
  --config            <file>  Additional Nextflow config file                   [default: none]
                              Settings in this file will override defaults.
                              The mcic-scripts OSC config file is always included
                              (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)
  --profile            <str>  Name of a 'profile' from a config file that       [default: $profile]
                              should be used

UTILITY OPTIONS:
  --conda_path        <dir>   Full path to a Nextflow Conda environment to use  [default: $conda_path]
  -h/--help                   Print help and exit
  -v/--version                Print the version of this script and of $TOOL_NAME
    
PIPELINE DOCUMENTATION:
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

nextflow_setup() {
    # Singularity container dir - any downloaded containers will be stored here;
    # if the required container is already there, it won't be re-downloaded
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    export NXF_SINGULARITY_LIBRARYDIR="$container_dir"
    mkdir -p "$NXF_SINGULARITY_CACHEDIR"

    # Limit memory for Nextflow main process - see https://www.nextflow.io/blog/2021/5_tips_for_hpc_users.html
    export NXF_OPTS='-Xms1g -Xmx4g'

    # Nextflow's new v2 config parser rejects the classic `if { withName: ... }`
    # pattern used in nf-core/sarek's modules.config - force the legacy v1 parser
    export NXF_SYNTAX_PARSER=v1
}

# ==============================================================================
#                          INFRASTRUCTURE SETUP I
# ==============================================================================
# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                     PARSE COMMAND-LINE OPTIONS
# ==============================================================================
# Initiate variables
version_only=false
fq_dir=
samplesheet=
ref_fasta=
outdir=
config_file=
params_file=
container_dir=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -o | --outdir )             shift && outdir=$1 ;;
        -p | --params )             shift && params_file=$1 ;;
        --fq_dir )                  shift && fq_dir=$1 ;;
        --samplesheet )             shift && samplesheet=$1 ;;
        --ref_fasta )               shift && ref_fasta=$1 ;;
        --workflow_version )        shift && workflow_version=$1 ;;
        --container_dir )           shift && container_dir=$1 ;;
        --config | -config )        shift && config_file=$1 ;;
        --profile | -profile )      shift && profile=$1 ;;
        --work_dir | -work-dir )    shift && work_dir=$1 ;;
        --restart | -restart )      resume=false && resume_arg= ;;
        -h | --help )               script_help; exit 0 ;;
        -v | --version )            version_only=true ;;
        * )                         die "Invalid option $1" "$all_opts";;
    esac
    shift
done

# Check input
[[ -z "$outdir" ]] && die "Please specify an output dir with -o/--outdir" "$all_opts"
[[ -z "$ref_fasta" ]] && die "Please specify a reference genome FASTA file with --ref_fasta" "$all_opts"
[[ -z "$params_file" ]] && die "No parameter YAML file specified, do so with -p/--params" "$all_opts"
[[ -z "$samplesheet" && -z "$fq_dir" ]] && die "No samplesheet or FASTQ dir specified: please specify one of these two --samplesheet or --fq_dir" "$all_opts"

[[ ! -f "$ref_fasta" ]] && die "Specified reference FASTA file $ref_fasta does not exist"
[[ ! -f "$params_file"  ]] && die "Specified input parameter YAML file $params_file does not exist"
[[ -n "$samplesheet" && ! -f "$samplesheet" ]] && die "Specified samplesheet $samplesheet does not exist"
[[ -n "$fq_dir" && ! -d "$fq_dir" ]] && die "Specified FASTQ dir $fq_dir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Bash strict settings
set -euo pipefail
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Build the config argument
OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_arg="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_arg="$config_arg -c ${config_file/,/ -c }"

# Other output dirs
[[ -z "$container_dir" ]] && container_dir="$work_dir"/containers
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script: $all_opts"
echo
echo "INPUT AND OUTPUT:"
[[ -n "$samplesheet" ]] && echo "Sample sheet:                             $samplesheet"
[[ -n "$fq_dir" ]] && echo "FASTQ file dir:                           $fq_dir"
echo "Reference genome FASTA file:              $ref_fasta"
echo "Output dir:                               $outdir"
echo "Parameter YAML file:                      $params_file"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Resume previous run?                      $resume"
echo "Container dir:                            $container_dir"
echo "Scratch (work) dir:                       $work_dir"
echo "Config 'profile':                         $profile"
[[ -n "$config_file" ]] && echo "Additional config file:                   $config_file"
echo "Config file argument:                     $config_arg"
echo "=========================================================================="
echo "Listing the input files:"
ls -lh "$ref_fasta"
echo "=========================================================================="
load_env "$conda_path"
nextflow_setup
set_threads "$IS_SLURM"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                              RUN
# ==============================================================================
# Make necessary output dirs
log_time "Creating the output and 'work' directories..."
mkdir -pv "$work_dir" "$container_dir" "$outdir"/logs

# Download the OSC config file
if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi

# Modify the config file so it uses the same OSC project as this job
if [[ "$osc_account" != "PAS0471" ]]; then
    sed -i "s/--account=PAS0471/--account=$osc_account/" "$OSC_CONFIG"
fi

# Create samplesheet if a FASTQ dir was provided instead of a samplesheet
if [[ -z "$samplesheet" ]]; then
    samplesheet="$outdir"/samplesheet.csv
    log_time "Creating samplesheet $samplesheet based on the files in FASTQ dir $fq_dir"
    
    echo "patient,sample,lane,fastq_1,fastq_2" > "$samplesheet"
    ls -1 "$fq_dir"/*fastq.gz |
        paste -d, - - |
        sed -E 's@.*/(.*)_S[0-9]+_(L00[0-9])@\1,\1,\2,&@' >> "$samplesheet"
fi

# Check the samplesheet
n_lines=$(tail -n+2 "$samplesheet" | wc -l)
n_samples=$(tail -n+2 "$samplesheet" | cut -f1 -d, | sort -u | wc -l)
log_time "The samplesheet contains $n_lines lines and $n_samples distinct samples. Showing the first lines:"
head "$samplesheet"

# Run the workflow
log_time "Starting the workflow run...\n"
runstats $TOOL_BINARY $WORKFLOW_NAME \
    -r $workflow_version \
    -params-file "$params_file" \
    --input "$samplesheet" \
    --fasta "$ref_fasta" \
    --outdir "$outdir" \
    -work-dir "$work_dir" \
    -ansi-log false \
    -profile "$profile" \
    $config_arg \
    $resume_arg

# Report
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
