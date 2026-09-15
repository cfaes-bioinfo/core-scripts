#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nfc_dualrnaseq
#SBATCH --output=slurm-nfc_dualrnaseq-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the nf-core dualRNAseq pipeline from https://nf-co.re/dualrnaseq"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY="nextflow run"
TOOL_NAME="nextflow"
VERSION_COMMAND="nextflow -v"

# Constants - parameters
WF_NAME=dualrnaseq            # The name of the nf-core workflow
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
OSC_CONFIG=mcic-scripts/nextflow/osc.config  # Will be downloaded if not present here
DUALRNASEQ_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/nfcore_dualrnaseq.config
DUALRNASEQ_CONFIG=mcic-scripts/nextflow/nfcore_dualrnaseq.config  # Will be downloaded if not present here

#FEATURE_TYPE_HOST="exon"
#FEATURE_TYPE_PATHOGEN="exon"
MAPPING_STATS=false
RUN_SALMON=true
RUN_STAR=true
SALMON_LIBTYPE=A              # Automatic detection

# Defaults - generic
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow-22.10 # This workflow was made in DSL1, does not work with latest Nextflow versions
container_dir=/fs/ess/PAS0471/containers
profile="singularity"
resume=true && resume_arg="-resume"

# Parameter defaults
wf_version=1.0.0                         # The version of the nf-core workflow
trimming=bbduk
work_dir=/fs/scratch/PAS0471/$USER/nfc_dualrnaseq
wf_dir_base=workflows/nfc_dualrnaseq
wf_dir_full="$wf_dir_base"/${wf_version//./_}
#host_attr=gene_id
#path_attr=gene_id

# ==============================================================================
#                                FUNCTIONS
# ==============================================================================
Print_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLES:"
    echo "  sbatch $0 -i "
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <dir>   Input directory with FASTQ files"
    echo "                                FASTQs should have extension '_R1.fastq.gz' (forward) and '_R2.fastq.gz' (reverse)"
    echo "  -o/--outdir         <dir>   Output directory for final workflow results (will be created if needed)"
    echo "  --host_fa           <file>  Host reference genome FASTA file (NOTE: extension has to be '.fa' or '.fasta')"
    echo "  --host_gff          <file>  Host reference genome annotation file in GFF (not GTF) format"
    echo "  --path_fa           <file>  Pathogen reference genome FASTA file (NOTE: extension has to be '.fa' or '.fasta')"
    echo "  --path_gff          <file>  Pathogen reference genome annotation file in GFF (not GTF) format"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --trimming          <str>   One of 'off', 'bbduk', or 'cutadapt'    [default: $trimming]"
    #echo "  --host_attr         <str>   Host GFF gene attribute/identifier      [default: $host_attr]'"
    #echo "  --path_attr         <str>   Pathogen GFF gene attribute/identifier  [default: $path_attr]"
    echo "  --wf_version        <str>   Nf-core dualRNAseq workflow version     [default: $wf_version]"
    echo "  --wf_dir            <dir>   Dir with/for the workflow repo          [default: $wf_dir_base]"
    echo "                                - If the correct version of the workflow is already present in this dir, it won't be downloaded again"
    echo "  --opts              <str>   Additional options to pass to $TOOL_NAME run"
    echo
    echo "NEXTFLOW-RELATED OPTIONS:"
    echo "  --restart                   Restart workflow from the beginning     [default: resume workflow if possible]"
    echo "  --container_dir     <dir>   Directory with container images         [default: $container_dir]"
    echo "                                - Required images will be downloaded here when not already present here"
    echo "  --config            <file>  Additional config file                  [default: none]"
    echo "                                - Settings in this file will override default settings"
    echo "                                - Note that the mcic-scripts OSC config file will always be included, too"
    echo "                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  --profile            <str>  'Profile' to use from one of the config files [default: $profile]"
    echo "  --work_dir           <dir>  Scratch (work) dir for the workflow     [default: $work_dir]"
    echo "                                - This is where the workflow results will be stored before final results are copied to the output dir."
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of Nextflow and exit"
    echo
    echo "GFF FILE NOTES:"
    echo "  - The nf-core workflow has specific requirements for GFF files, and seems to fail with most"
    echo "    unedited GFF files. Edit the GFF file to make sure:"
    echo "        - It has a 'gene_id' attribute in the last column, with the gene ID"
    echo "        - There are (dummy) 'gene_name' and 'gene_type' attributes in the last column"
    echo "  - The script will use 'exon' as the focal feature type (3rd column in GFF)"
    echo
    echo "NFCORE RNASEQ WORKFLOW DOCUMENTATION:"
    echo "   - https://nf-co.re/dualrnaseq"
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
    export SINGULARITY_CACHEDIR="$container_dir"
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    mkdir -p "$container_dir"

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
#                     PARSE COMMAND-LINE OPTIONS
# ==============================================================================
version_only=false
indir=
host_fa=
host_gff=
path_fa=
path_gff=
outdir=
config_file=
opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )              shift && indir=$1 ;;
        -o | --outdir )             shift && outdir=$1 ;;
        --host_fa )                 shift && host_fa=$1 ;;
        --host_gff )                shift && host_gff=$1 ;;
        --path_fa )                 shift && path_fa=$1 ;;
        --path_gff )                shift && path_gff=$1 ;;
        #--host_attr )               shift && host_attr=$1 ;;
        #--path_attr )               shift && path_attr=$1 ;;
        --trimming )                shift && trimming=$1 ;;
        --container_dir )           shift && container_dir=$1 ;;
        --opts )                    shift && opts=$1 ;;
        --config | -config )        shift && config_file=$1 ;;
        --profile | -profile )      shift && profile=$1 ;;
        --work_dir | -work-dir )    shift && work_dir=$1 ;;
        --restart | -restart )      resume=false && resume_arg= ;;
        -h | --help )               script_help; exit 0 ;;
        -v | --version )                 version_only=true ;;
        * )                         script_help; die "Invalid option $1";;
    esac
    shift
done

# Check input
[[ -z "$indir" ]] && die "Please specify an input dir with -i/--indir" "$all_opts"
[[ -z "$host_fa" ]] && die "Please specify a host FASTA file with --host_fa" "$all_opts"
[[ -z "$host_gff" ]] && die "Please specify a host GFF file with --host_gff" "$all_opts"
[[ -z "$path_fa" ]] && die "Please specify a pathogen FASTA file with --path_fa" "$all_opts"
[[ -z "$path_gff" ]] && die "Please specify a pathogen GFF file with --path_gff" "$all_opts"
[[ -z "$outdir" ]] && die "Please specify an output dir with -o" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"
[[ ! -f "$host_fa" ]] && die "Host FASTA file $host_fa does not exist"
[[ ! -f "$host_gff" ]] && die "Host GFF file $host_gff does not exist"
[[ ! -f "$path_fa" ]] && die "Pathogen FASTA file $path_fa does not exist"
[[ ! -f "$path_gff" ]] && die "Pathogen GFF file $path_gff does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Bash strict settings
set -euo pipefail

# Load software
load_env "$conda_path"
nextflow_setup
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Build the trimming arg
if [[ "$trimming" == bbduk ]]; then
    trimming_arg="--run_bbduk"
elif [[ "$trimming" == cutadapt ]]; then
    trimming_arg="--run_cutadapt"
elif [[ "$trimming" == "off" ]]; then
    trimming_arg=
else
    die "--trimming should be 'bbduk', 'cutadapt', or 'off', but was $trimming"
fi

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
echo "Input FASTQ dir:                  $indir"
echo "Host FASTA file:                  $host_fa"
echo "Host GFF file:                    $host_gff"
echo "Pathogen FASTA file:              $path_fa"
echo "Pathogen GFF file:                $path_gff"
echo "Output dir:                       $outdir"
echo
echo "SETTINGS:"
echo "FASTQ trimming:                   $trimming"
#echo "Host GFF attribute:               $host_attr"
#echo "Pathogen GFF attribute:           $path_attr"
[[ -n "$opts" ]] && echo "Additional options:               $opts"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Resume previous run:              $resume"
echo "Container dir:                    $container_dir"
echo "Scratch (work) dir:               $work_dir"
echo "Nextflow workflow dir:            $wf_dir_full"
echo "Config 'profile':                 $profile"
[[ -n "$config_file" ]] && echo "Additional config file:                       $config_file"
log_time "Listing the reference genome files:"
ls -lh "$host_fa" "$host_gff" "$path_fa" "$path_gff"
log_time "# Listing the files in the FASTQ dir:"
ls -lh "$indir"/*fastq.gz
echo "=========================================================================="
set_threads "$IS_SLURM"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                              CONFIG FILES
# ==============================================================================
# Download the config files, if needed
[[ ! -f "$OSC_CONFIG" ]] && OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
[[ ! -f "$DUALRNASEQ_CONFIG" ]] && DUALRNASEQ_CONFIG="$outdir"/$(basename "$DUALRNASEQ_CONFIG_URL")

if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi
if [[ ! -f "$DUALRNASEQ_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $DUALRNASEQ_CONFIG..."
    wget -q -O "$DUALRNASEQ_CONFIG" "$DUALRNASEQ_CONFIG_URL"
fi

# Modify the config file: add paths to GFF files
#? Somehow GFF files need to be specified in the config file and not on the command-line -- the latter returns errors
DUALRNASEQ_CONFIG_FINAL="$outdir"/$(basename "$DUALRNASEQ_CONFIG" .config)_final.config

log_time "Adding GFF file paths to the config file $DUALRNASEQ_CONFIG_FINAL"
sed -E "s@gff_host = .*@gff_host = \"$host_gff\"@" "$DUALRNASEQ_CONFIG" |
    sed -E "s@gff_pathogen = .*@gff_pathogen = \"$path_gff\"@" \
    > "$DUALRNASEQ_CONFIG_FINAL"

# Without this, seems to ignore the Container location
echo -e "\nsingularity.cacheDir = \"$container_dir\"" >> "$DUALRNASEQ_CONFIG_FINAL"

log_time "Showing the contents of the final dualRNAseq config file:"
cat -n "$DUALRNASEQ_CONFIG_FINAL"
echo "--------------------------------"

# Build the final config argument
config_arg="-c $OSC_CONFIG -c $DUALRNASEQ_CONFIG_FINAL"
[[ -n "$config_file" ]] && config_arg="$config_arg -c ${config_file/,/ -c }"
log_time "Final config file argument:             $config_arg"

# ==============================================================================
#                              RUN
# ==============================================================================
# Make necessary dirs
log_time "Creating the output directories..."
mkdir -pv "$work_dir" "$container_dir" "$outdir"/logs "$trace_dir"

# Download workflow, if needed
if [[ ! -d "$wf_dir_full" ]]; then
    mkdir -p "$(dirname "$wf_dir_base")"
    log_time "Downloading the workflow repository to $wf_dir_base"
    runstats nf-core download "$WF_NAME" \
        --revision "$wf_version" \
        --compress none \
        --container-system singularity \
        --parallel-downloads "$threads" \
        --outdir "$wf_dir_base" \
        --force
else
    log_time "Workflow repository dir was found at $wf_dir_base, not downloading..."
fi

# Run the workflow
log_time "Starting the workflow.."
runstats $TOOL_BINARY \
    "$wf_dir_full" \
    --outdir "$outdir" \
    --input "$indir/*_R{1,2}*fastq.gz" \
    --fasta_host "$host_fa" \
    --fasta_pathogen "$path_fa" \
    --genomes_ignore \
    --mapping_statistics "$MAPPING_STATS" \
    --run_star "$RUN_STAR" \
    --run_salmon_alignment_based_mode "$RUN_SALMON" \
    --libtype "$SALMON_LIBTYPE" \
    $trimming_arg \
    -work-dir "$work_dir" \
    -with-report "$trace_dir"/report.html \
    -with-trace "$trace_dir"/trace.txt \
    -with-timeline "$trace_dir"/timeline.html \
    -with-dag "$trace_dir"/dag.png \
    -ansi-log false \
    -profile "$profile" \
    $config_arg \
    $resume_arg \
    $opts

#    --host_gff_attribute "$host_attr" \
#    --pathogen_gff_attribute "$path_attr" \
#    --gene_feature_gff_to_quantify_host "$FEATURE_TYPE_HOST" \
#    --gene_feature_gff_to_quantify_pathogen "$FEATURE_TYPE_PATHOGEN" \

#? Adding '--genomes_ignore' seems necessary to run the workflow but doesn't seem to do anything
#? For the workflow's own config file, see see ~/.nextflow/assets/nf-core/dualrnaseq/nextflow.config

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"


#===============================================================================
# Because nf-core failed to download the container, I included code to manually
#   download it before running the workflow - see below.
#   However, this is not necessary because the workflow itself will download it.

#container_url=docker://nfcore/dualrnaseq:1.0.0
#url_basename=$(basename "$container_url")
#container_path="$container_dir"/${url_basename/:/_}.sif
#if [[ ! -f "$container_path" ]]; then
#    log_time "Downloading container from $container_url to $container_path"
#    singularity pull --force "$container_path" "$container_url"
#else
#    log_time "Container was found at $container_path, not downloading..."
#fi
