#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=5:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=ghru_assembly
#SBATCH --output=slurm-ghru_assembly-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generics
DESCRIPTION="Run the modified GHRU assembly pipeline to assemble bacterial genomes"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY="nextflow run"
export TOOL_NAME="nextflow"
VERSION_COMMAND="nextflow -v"

# Constants - parameters
WORKFLOW_URL=https://github.com/jelmerp/ghru_assembly
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
OSC_CONFIG=mcic-scripts/nextflow/osc.config  # Will be downloaded if not present here
OSC_PROJ=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")

# Defaults - generics
workflow_dir="workflows/ghru_assembly"
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow-22.10 # Need this older version because it's a DSL1 Workflow
container_dir=/fs/ess/PAS0471/containers
work_dir=/fs/scratch/$OSC_PROJ/$USER/ghru_assembly
profile="standard,singularity"
resume=true && resume_arg="-resume"
version_only=false

# Defaults - settings
outdir="results/ghru_assembly"
fastq_pattern='*R{1,2}*.fastq.gz'
careful=false && careful_opt=

# ==============================================================================
#                                FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLES:"
    echo "  - Always submit this script to the Slurm queue with sbatch"
    echo "  - Examples:"
    echo "    sbatch $0 --indir data/fastq"
    echo "    sbatch $0 --indir data/fastq --outdir results/assembly"
    echo "    sbatch $0 --indir data/fastq --careful --more_opts '--depth_cutoff 50'"
    echo "    sbatch $0 --indir data/fastq --fastq_pattern '*_R{1,2}.fq.gz'"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i / --indir        <dir>   Input directory with FASTQ files"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  -o / --outdir       <dir>   Output directory for workflow results   [default: 'results/ghru_assembly']"
    echo "  --fastq_pattern     <str>   FASTQ file pattern (glob)               [default: \"*R{1,2}*.fastq.gz\"]"
    echo "                                - Use this option if your file names don't adhere to the default, e.g. if they are 'fq.gz'"
    echo "                                - You can also use this option to select only a subset of files, e.g. 'sampleA*R{1,2}*.fastq.gz'"
    echo "  --careful                   Turn on the SPAdes 'careful' option which improves assembly by mapping the reads back to the contigs"
    echo "  --more_opts         <str>   Additional options to pass to 'nextflow run'"
    echo "                                - You can use any additional option of Nextflow and of the Nextflow workflow itself"
    echo "                                - Use as follows (quote the entire string!): '$0 --more_opts \"--minimum_scaffold_depth 10\"'"
    echo "                                - The following additional options exist for this workflow:"
    echo "                                  --depth_cutoff                  The estimated depth to downsample each sample to. If not specified no downsampling will occur"
    echo "                                  --minimum_scaffold_length       The minimum length of a scaffold to keep. Others will be filtered out. Default 500"
    echo "                                  --minimum_scaffold_depth        The minimum depth of coverage a scaffold must have to be kept. Others will be filtered out. Default 3"
    echo "                                  --confindr_db_path              The path to the confindr database."
    echo "                                  --prescreen_genome_size_check   Size in bp of the maximum estimated genome to assemble. Without this any size genome assembly will be attempted"
    echo "                                  --prescreen_file_size_check     Minumum size in Mb for the input fastq files. Without this any size of file will be attempted (this and prescreen_genome_size_check are mutually exclusive)"
    echo
    echo "NEXTFLOW-RELATED OPTIONS:"
    echo "  --restart                   Restart workflow from the beginning     [default: Resume workflow whenever possible]"
    echo "  --workflow_dir      <dir>   Dir with/for the workflow repo          [default: $workflow_dir]"
    echo "                                - If the correct workflow is already present in this dir, it won't be downloaded again"
    echo "  --container_dir     <dir>   Directory with container images         [default: $container_dir]"
    echo "                                - Required container images will be downloaded here when not already present"
    echo "  --profile           <str>   'Profile' name from any of the config files to use   [default: 'standard,singularity']"
    echo "  --work_dir           <dir>  Scratch (work) dir for the workflow     [default: $work_dir]"
    echo "                                - This is where the workflow results will be stored before final results are copied to the output dir."
    echo "                                - It's a good idea to use a 'scratch' dir here"
    echo "  --version                   Print the version of Nextflow and exit"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo
    echo "HARDCODED PARAMETERS:"
    echo "This script always uses:"
    echo "  - The '--full_output' option of the Nextflow workflow, which means that e.g. corrected FASTQ files are output"
    echo "  - The 'qc_conditions.yml' provided with the workflow for Qualifyr assembly QC"
    echo "  - The 'adapters.fas' adapter file provided with the workflow is used with the '--adapter_file' option"
    echo
    echo "DOCUMENTATION:"
    echo "  - This script runs a slightly modified version of the GHRU assembly pipeline: https://gitlab.com/cgps/ghru/pipelines/assembly"
    echo "  - It uses the Docker container provided by the GHRU workflow, ran with Singularity"
    echo "  - Main changes made to the original GHRU workflow:"
    echo "    - Removed 'kat' command in process 'genome_size_estimation' and replaced the resulting 'minima' variable with a"
    echo "      hardcoded value of '3', as per Bactopia in <https://github.com/bactopia/bactopia/blob/master/modules/local/bactopia/gather_samples/main.nf>."
    echo "    - Due to errors related to the Confindr database in the default container, I changed the 'confindr.py' command in 'check_for_contamination'."
    echo "      That is, I removed the '-d' argument, since databases are not needed for Salmonella, see <https://github.com/OLC-Bioinformatics/ConFindr>"
    echo "      See also <https://olc-bioinformatics.github.io/ConFindr/install/#downloading-confindr-databases>."
    echo "    - Added 'publishDir' directives to 'genome_size_estimation' and 'species_identification' (bactinspector),"
    echo "      so that the output of these programs ends up in the output dir."
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

# Placeholder variables
indir=
more_opts=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )              shift && indir=$1 ;;
        -o | --outdir )             shift && outdir=$1 ;;
        --fastq_pattern )           shift && fastq_pattern=$1 ;;
        --careful )                 careful=true && careful_opt="--careful" ;;
        --workflow_dir )            shift && workflow_dir=$1 ;;
        --container_dir )           shift && container_dir=$1 ;;
        --profile | -profile )      shift && profile=$1 ;;
        --work_dir | -work-dir )    shift && work_dir=$1 ;;
        --restart | -restart )      resume=false && resume_arg= ;;
        --more_opts )               shift && more_opts=$1 ;;
        -h | --help )               script_help; exit 0 ;;
        -v | --version )                 version_only=true ;;
        * )                         script_help; die "Invalid option $1";;
    esac
    shift
done

# Check input
[[ -z "$indir" ]] && die "Please specify an input dir with -i" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Bash strict settings
set -euo pipefail

# Load software
load_env "$conda_path"
nextflow_setup
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Build the config argument
[[ ! -f "$OSC_CONFIG" ]] && OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_arg="-c $OSC_CONFIG"

# Input files that should be in the workflow repository
QC_YAML="$workflow_dir"/assets/qc_conditions.yml
ADAPTER_FILE="$workflow_dir"/assets/adapters.fas

# Other output dirs
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
trace_dir="$outdir"/pipeline_info

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script: $all_opts"
echo
echo "INPUT AND OUTPUT:"
echo "Input dir:                        $indir"
echo "FASTQ file pattern:               $fastq_pattern"
echo "Output dir:                       $outdir"
echo
echo "OTHER WORKFLOW SETTINGS:"
echo "Use SPAdes 'careful' option:      $careful"
[[ -n "$more_opts" ]] && echo "Additional options:               $more_opts"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Nextflow workflow file:           $workflow_dir"
echo "Resume previous run:              $resume"
echo "Container dir:                    $container_dir"
echo "Scratch (work) dir:               $work_dir"
echo "Config 'profile':                 $profile"
echo "=========================================================================="
set_threads "$IS_SLURM"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                              RUN
# ==============================================================================
# Make necessary dirs
log_time "Creating the output directories..."
mkdir -pv "$work_dir" "$container_dir" "$outdir"/logs "$trace_dir"

# Download the OSC config file
if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi

# Download workflow, if needed
if [[ ! -d "$workflow_dir" ]]; then
    log_time "Downloading the GHRU assembly workflow from $WORKFLOW_URL to $workflow_dir" 
    git clone $WORKFLOW_URL "$workflow_dir"
fi

# Check that workflow files are present
[[ ! -f "$ADAPTER_FILE" ]] && die "Adapter file $ADAPTER_FILE does not exist"
[[ ! -f "$QC_YAML" ]] && die "QC Yaml file $QC_YAML does not exist"
[[ ! -f "$workflow_dir"/main.nf ]] && die "Workflow file $workflow_dir/main.nf does not exist"

# Run the workflow
log_time "Starting the workflow.."
runstats $TOOL_BINARY "$workflow_dir"/main.nf \
    --indir $indir \
    --outdir $outdir \
    --fastq_pattern "$fastq_pattern" \
    --adapter_file $ADAPTER_FILE \
    --qc_conditions $QC_YAML \
    --full_output \
    $careful_opt \
    -work-dir $work_dir \
    -ansi-log false \
    -with-report $trace_dir/report.html \
    -with-trace $trace_dir/trace.txt \
    -with-timeline $trace_dir/timeline.html \
    -with-dag $trace_dir/dag.png \
    -profile $profile \
    $config_arg \
    $resume_arg \
    $more_opts

# Report
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
