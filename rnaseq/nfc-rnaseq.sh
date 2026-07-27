#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=48:00:00
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nfc_rnaseq
#SBATCH --output=slurm-nfc_rnaseq-%j.out

#TODO - Edit MultiQC config so it doesn't include samtools stats

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the Nextflow-core RNAseq pipeline from https://nf-co.re/rnaseq
  with aligner option STAR => Salmon"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY="nextflow run"
export TOOL_NAME="nextflow"
VERSION_COMMAND="nextflow -v"

# Constants - specific
WORKFLOW_NAME=nf-core/rnaseq                           # The name of the nf-core workflow
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config # Nextflow <=> OSC config file
ALIGNER_OPT="--aligner star_salmon "                   # Always use STAR => Salmon

# Defaults - pipeline parameters
workflow_version=3.26.0                                # The version of the nf-core workflow
resume=true && resume_arg="-resume"                    # Resume the workflow from wherever it left off
biotype_qc=false                                       # Activate --skip_biotype_qc option of the workflow
salmon_gcbias=true                                     # Pass the --gcBias option to Salmon
salmon_seqbias=true                                    # Pass the --seqBias option to Salmon
rm_rrna=true                                           # Run SortMeRNA to remove rRNA

# Defaults - infrastructure
conda_path=/fs/ess/PAS0471/jelmer/conda/nextflow   # Conda environment with Nextflow & nf-core tools
osc_account=PAS0471                                    # If the script is submitted with another project, this will be updated (line below)
[[ -n $SLURM_JOB_ACCOUNT ]] && osc_account=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")
container_dir=/fs/scratch/"$osc_account"/containers    # The workflow will download containers to this dir
work_dir=/fs/scratch/"$osc_account"/$USER/nfc-rnaseq   # 'work dir' for initial outputs (selected, final outputs go to the outdir)
profile="singularity"                                  # 'singularity' to have the workflow use containers (alternatively, 'conda')
version_only=false                                     # When true, just print tool & script version info and exit 

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
    echo "  sbatch $0 -i samplesheet.csv --ref_fasta data/ref/my.fa --ref_annot data/ref/my.gtf -o results/nfc_rnaseq"
    echo "  sbatch $0 -i samplesheet.csv --ref_fasta data/ref/my.fa --ref_annot data/ref/my.gtf -o results/nfc_rnaseq \\"
    echo "    --more_opts \"--skip_bbsplit false --bbsplit_fasta_list contaminant_refs.csv\""
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--samplesheet    <file>  Sample sheet containing paths to FASTQ files and sample info"
    echo "                                - See example code below, and https://nf-co.re/rnaseq/docs/usage#samplesheet-input for more details"
    echo "  -o/--outdir         <dir>   Output directory (will be created if needed)"
    echo "  --ref_fasta         <file>  Reference genome FASTA file"
    echo "  --ref_annot         <file>  Reference genome annotation file (GTF/GFF - GTF format preferred)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --workflow_version  <str>   Nf-core rnaseq workflow version         [default: $workflow_version]"
    echo "  --biotype_qc                Run FeatureCounts' biotype QC           [default: $biotype_qc]"
    echo "                                Turned off by default because this will often result in runtime errors"
    echo "  --no_gcbias                 Don't use the Salmon '--gcBias' option  [default: use this option]"
    echo "  --no_seqbias                Don't use the Salmon '--seqBias' option [default: use this option]"
    echo "  --no_rrna_removal           Don't run SortMeRNA to remove rRNA      [default: remove rRNA]"
    echo "  --more_opts         <str>   Additional workflow parameters, for usage see example above"
    echo "                                 Available workflow parameters are listed at https://nf-co.re/rnaseq/parameters"
    echo "                                 Some useful ones include:"
    echo "                                   - '--save_reference' to save the reference genome index file"
    echo "                                   - '--save_merged_fastq' to save merged FASTQ files (in case of technical duplicates)"
    echo "                                   - '--save_non_ribo_reads' to save the FASTQ files after rRNA filtering (= final FASTQ before mapping)"
    echo
    echo "NEXTFLOW-RELATED OPTIONS:"
    echo "  --restart                   Restart workflow from the beginning     [default: resume workflow if possible]"
    echo "  --container_dir     <dir>   Directory with container images         [default: $container_dir]"
    echo "                                - Required container images will be downloaded here when not already present" 
    echo "  --config            <file>  Additional Nextflow config file         [default: none]"
    echo "                                - Settings in this file will override default settings"
    echo "                                - Note that the mcic-scripts OSC config file will always be included"
    echo "                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  --profile            <str>  Name of a 'profile' from a config file that should be used [default: $profile]"
    echo "  --work_dir           <dir>  Scratch (work) dir for the workflow     [default: $work_dir]"
    echo "                                - This is where the workflow results will be stored before final results are copied to the output dir."
    echo "  --version                   Print the version of Nextflow and exit"
    echo
    echo "UTILITY OPTIONS"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo
    echo "HARDCODED WORKFLOW OPTIONS & DEFAULTS THAT DIFFER FROM THE WORKFLOW DEFAULTS:"
    echo "  - The option '--aligner star_salmon' is hardcoded (always used)"
    echo "  - Defaults of this script that differ from the workflow's defaults:"
    echo "      - Using the Salmon '--gcBias' and '--seqBias' options (see '--no_gcbias' and '--no_seqbias' script options above)"
    echo "      - Removing rRNA with SortmeRNA using the --remove_ribo_rna option"
    echo "      - Using the workflow's '--skip_biotype_qc' option, since FeatureCounts biotype QC often results in errors due to GTF file differences"
    echo "          (see the '--biotype_qc' option of this script above)"
    echo
    echo "SOME KEY OUTPUT FILES:"
    echo "  - HTML file with summary of results: <outdir>/multiqc/star_salmon/multiqc_report.html"
    echo "  - Gene counts for use with DESeq2 in <outdir>/star_salmon/salmon.merged.gene_counts_length_scaled.rds"
    echo "    Use the script 'mcic-scripts/rnaseq/nfcore_rnaseq_mkdeseq.R' to get started with that."
    echo
    echo "NFCORE RNASEQ WORKFLOW DOCUMENTATION:"
    echo "   - https://nf-co.re/rnaseq "
    echo
    echo "EXAMPLE CODE FOR CREATING THE SAMPLE SHEET:"
    echo "  wget -L https://raw.githubusercontent.com/nf-core/rnaseq/master/bin/fastq_dir_to_samplesheet.py"
    echo "  fqdir=data/fastq                         # Dir with your FASTQ files"
    echo "  samplesheet=data/meta/samplesheet.csv    # Output samplesheet"
    echo "  python3 fastq_dir_to_samplesheet.py \$fqdir \$samplesheet --strandedness reverse"
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
    export NXF_SINGULARITY_LIBRARYDIR="$container_dir"
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
#                     PARSE COMMAND-LINE OPTIONS
# ==============================================================================
samplesheet=
ref_annot=
ref_fasta=
outdir=
config_file=
more_opts=
threads=
biotype_opt=
salmon_opts=
rrna_opt=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --samplesheet )        shift && samplesheet=$1 ;;
        -o | --outdir )             shift && outdir=$1 ;;
        --ref_annot )               shift && ref_annot=$1 ;;
        --ref_fasta )               shift && ref_fasta=$1 ;;
        --biotype_qc )              biotype_qc=true ;;
        --no_gcbias )               salmon_gcbias=false ;;
        --no_seqbias )              salmon_seqbias=false ;;
        --no_rrna_removal )         rm_rrna=false ;;
        --more_opts )               shift && more_opts=$1 ;;
        --workflow_version )        shift && workflow_version=$1 ;;
        --container_dir )           shift && container_dir=$1 ;;
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
[[ -z "$samplesheet" ]] && die "Please specify a samplesheet with -i" "$all_opts"
[[ -z "$ref_fasta" ]] && die "Please specify a genome FASTA file with -f" "$all_opts"
[[ -z "$ref_annot" ]] && die "Please specify an annotation (GFF/GTF) file with -g" "$all_opts"
[[ -z "$outdir" ]] && die "Please specify an output dir with -o" "$all_opts"
[[ ! -f "$samplesheet" ]] && die "Samplesheet $samplesheet does not exist"
[[ ! -f "$ref_fasta" ]] && die "Reference FASTA file $ref_fasta does not exist"
[[ ! -f "$ref_annot" ]] && die "Reference annotation file $ref_annot does not exist"

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
OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_arg="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_arg="$config_arg -c ${config_file/,/ -c }"

# Setup Nextflow arguments: annotation filetype
if [[ "$ref_annot" =~ .*\.gff ]]; then
    annot_opt="--gff $ref_annot"
elif [[ "$ref_annot" =~ .*\.gtf ]]; then
    annot_opt="--gtf $ref_annot"
else
    die "Annotation file $ref_annot should have extension '.gff'. or '.gtf' - please rename .gff3 files to .gff"
fi

# Other opts
[[ "$biotype_qc" == false ]] && biotype_opt="--skip_biotype_qc"
[[ "$rm_rrna" == true ]] && rrna_opt="--remove_ribo_rna"
if [[ "$salmon_gcbias" == true ]]; then
   [[ "$salmon_seqbias" == true ]] && salmon_opts=(--extra_salmon_quant_args '--gcBias --seqBias')
   [[ "$salmon_seqbias" == false ]] && salmon_opts=(--extra_salmon_quant_args ' --gcBias')
else
    [[ "$salmon_seqbias" == true ]] && salmon_opts=(--extra_salmon_quant_args ' --seqBias')
fi

# Check nr of samples
nsamples=$(tail -n+2 "$samplesheet" | wc -l)

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
echo "Sample sheet:                     $samplesheet"
echo "Nr of samples in the samplesheet: $nsamples"
echo "Reference genome FASTA file:      $ref_fasta"
echo "Reference genome annotation file: $ref_annot"
echo "Output dir:                       $outdir"
echo
echo "OTHER WORKFLOW SETTINGS:"
echo "Run biotype QC?                   $biotype_qc"
echo "Use Salmon '--gcBias' option?     $salmon_gcbias"
echo "Use Salmon '--seqBias' option?    $salmon_seqbias"
echo "Remove rRNA with sortMeRNA?       $rm_rrna"
[[ -n "$more_opts" ]] && echo "Additional options:               $more_opts"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Resume previous run?              $resume"
echo "Container dir:                    $container_dir"
echo "Scratch (work) dir:               $work_dir"
echo "Config 'profile':                 $profile"
[[ -n "$config_file" ]] && echo "Additional config file:           $config_file"
echo "Config file argument:             $config_arg"
echo "=========================================================================="
echo "Listing the input files and showing the first lines of the samplesheet:"
ls -lh "$ref_fasta" "$ref_annot"
echo
head "$samplesheet"
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

# Modify the config file so it has the correct OSC project/account
if [[ "$osc_account" != "PAS0471" ]]; then
    sed -i "s/--account=PAS0471/--account=$osc_account/" "$OSC_CONFIG"
fi

# Run the workflow
log_time "Starting the workflow.."
runstats $TOOL_BINARY $WORKFLOW_NAME \
    -r $workflow_version \
    --input "$samplesheet" \
    --outdir "$outdir" \
    --fasta "$ref_fasta" \
    $annot_opt \
    $rrna_opt \
    $ALIGNER_OPT \
    "${salmon_opts[@]}" \
    $biotype_opt \
    -work-dir "$work_dir" \
    -with-report "$trace_dir"/report.html \
    -with-trace "$trace_dir"/trace.txt \
    -with-timeline "$trace_dir"/timeline.html \
    -with-dag "$trace_dir"/dag.png \
    -ansi-log false \
    -profile "$profile" \
    $config_arg \
    $resume_arg \
    $more_opts

# Report
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
