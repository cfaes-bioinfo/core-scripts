#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=5:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --job-name=ghru_phylogeny
#SBATCH --output=slurm-ghru_phylogeny-%j.out

# FUNCTIONS --------------------------------------------------------------------
## Help function
function Help() {
    echo
    echo "=================================================================================================="
    echo "                $0: Script to run a bacterial SNP phylogeny pipeline"
    echo "=================================================================================================="
    echo
    echo "REQUIRED OPTIONS:"
    echo "------------------"
    echo "  -i / --indir DIR              Input directory with FASTQ files"
    echo "  -f / --reference FILE         Referece genome FASTA file"
    echo
    echo
    echo "OTHER KEY OPTIONS:"
    echo "------------------"
    echo "  -o / --outdir DIR             Output directory for workflow results       [default: 'results/ghru_phylogeny']"
    echo
    echo "  -g / --fastq_pattern STRING   Single-quoted FASTQ file pattern (glob)     [default: '*R{1,2}*.fastq.gz']"
    echo "                                  - Use this option if your file names don't adhere to the default, e.g. if they are 'fq.gz'"
    echo "                                  - You can also use this option to select only a subset of files, e.g. 'sampleA*R{1,2}*.fastq.gz'"
    echo
    echo "  -r / --no_resume              Start workflow from beginning               [default: resume where it left off]"
    echo
    echo "  -a / --more_args STRING       Additional arguments to pass to 'nextflow run'"
    echo "                                  - You can use any additional option of Nextflow and of the Nextflow workflow itself"
    echo "                                  - Use as follows (quote the entire string!): '$0 --more_args \"--option_name option_value\"'"
    echo "                                  - The following additional options exist for this workflow:"
    echo "                                       TO BE ADDED"
    echo
    echo
    echo "OPTIONS YOU PROBABLY DON'T NEED TO USE:"
    echo "---------------------------------------"
    echo "  -n / --nextflow_file FILE     Workflow definition file (a '*.nf' file)"
    echo "                                [default: '/fs/ess/PAS0471/jelmer/assist/2022-09_alejandra/workflows/ghru_snp_phylogeny/main.nf']"
    echo
    echo "  -p / --profile STRING         Profile from any of the config files to use [default: 'standard,singularity']"
    echo
    echo "  -c / --config FILE            Additional config file(s)"
    echo "                                  - Any settings in this file will override settings in default config files"
    echo "                                  - Use a comma-separated list when supplying multiple files" 
    echo "                                  - The mcic-scripts OSC config will always be used, https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config"
    echo
    echo "  -t / --container_dir DIR      Singularity container dir                   [default: '/fs/ess/PAS0471/containers']"
    echo "                                  - This is where any containers used in the workflow will be downloaded to"
    echo
    echo "  -w DIR / --work_dir           'work' (scratch) dir for the workflow       [default: '/fs/scratch/PAS0471/$USER/ghru_phylogeny']"
    echo "                                  - This is where the workflow results will be stored before final results are copied to the specified output dir"
    echo "                                  - This should preferable be a dir in OSC's scratch dir rather than in the main project dir"
    echo
    echo
    echo "UTILITY OPTIONS:"
    echo "------------------"
    echo "  -x / --debug                  Turn on debugging/dry-run mode: print run information, but don't run commands"
    echo "  -h / --help                   Print this help message and exit"
    echo
    echo
    echo "EXAMPLE COMMANDS:"
    echo "------------------"
    echo "  sbatch $0 --indir data/fastq --reference data/res/my_ref.fasta"
    echo "  sbatch $0 --indir data/fastq --reference data/res/my_ref.fasta --fastq_pattern '*_R{1,2}.fq.gz'"
    echo
    echo "DOCUMENTATION:"
    echo "------------------"
    echo "- This script runs a workflow based on the GHRU SNP phylogeny workflow https://gitlab.com/cgps/ghru/pipelines/snp_phylogeny"
    echo "- It uses the Docker container provided by the GHRU workflow, ran with Singularity"
    echo
}

## Exit upon error with a message
function Die() {
    printf "\n$0: ERROR: %s\n" "$1" >&2
    echo -e "Exiting\n" >&2
    exit 1
}

## Load Nextflow
function Load_software() {
    module load miniconda3/4.12.0-py39
    source activate /fs/ess/PAS0471/jelmer/conda/nextflow

    ## Singularity container dir - any downloaded containers will be stored here
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    ## Limit memory for Nextflow main process - see https://www.nextflow.io/blog/2021/5_tips_for_hpc_users.html
    export NXF_OPTS='-Xms1g -Xmx4g'
}


# CONSTANTS AND DEFAULTS -------------------------------------------------------
## URL to OSC Nextflow config file
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
osc_config=mcic-scripts/nextflow/osc.config  # Will be downloaded if not present here

## Option defaults
fastq_pattern='*R{1,2}*.fastq.gz'
nextflow_file="/fs/ess/PAS0471/jelmer/assist/2022-09_alejandra/workflows/ghru_snp_phylogeny/main.nf"
outdir="results/ghru_phylogeny"
container_dir=/fs/ess/PAS0471/containers
work_dir=/fs/scratch/PAS0471/$USER/ghru_phylogeny
profile="standard,singularity"
resume=true && resume_arg="-resume"
debug=false


# PARSE COMMAND-LINE OPTIONS ---------------------------------------------------
indir=""
config_file=""
more_args=""

## Parse command-line options
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )          shift && indir=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        -f | --reference )      shift && reference=$1 ;;
        -g | --fastq_pattern )  shift && fastq_pattern=$1 ;;
        -n | --nextflow_file )  shift && nextflow_file=$1 ;;
        -w | --work_dir )    shift && work_dir=$1 ;;
        -t | --container_dir )  shift && container_dir=$1 ;;
        -p | --profile )        shift && profile=$1 ;;
        -c | --config_file )    shift && config_file=$1 ;;
        -a | --more_args )      shift && more_args=$1 ;;
        -x | --debug )          debug=true ;;
        -r | --no_resume )      resume=false ;;
        -h | --help )           Help && exit ;;
        * )                     Die "Invalid option $1" ;;
    esac
    shift
done

# OTHER SETUP ------------------------------------------------------------------
## Load Conda environment
Load_software

## Bash strict settings
set -ueo pipefail

## Input files that should be in the workflow repository
ADAPTER_FILE=$(dirname "$nextflow_file")/assets/adapters.fas

## Check input
[[ "$indir" = "" ]] && Die "Please specify an input dir with -i/--indir"
[[ "$reference" = "" ]] && Die "Please specify an input dir with -f/--reference"
[[ ! -d "$indir" ]] && Die "Input dir $indir does not exist"
[[ ! -f "$reference" ]] && Die "Reference FASTA file $reference does not exist"
[[ ! -f "$nextflow_file" ]] && Die "Nextflow file $nextflow_file does not exist"
[[ ! -f "$ADAPTER_FILE" ]] && Die "Adapter file $ADAPTER_FILE does not exist"

## Get the OSC config file
if [[ ! -f "$osc_config" ]]; then
    wget -q "$OSC_CONFIG_URL"
    osc_config=$(basename "$OSC_CONFIG_URL")
fi

## Build the config argument
config_arg="-c $osc_config"
if [[ "$config_file" != "" ]]; then
    config_arg="$config_arg -c ${config_file/,/ -c }"
fi

[[ "$resume" = false ]] && resume_arg=""

## Define trace output dir
trace_dir="$outdir"/pipeline_info

## Report
echo
echo "=========================================================================="
echo "                  STARTING SCRIPT GHRU_SNP_PHYLOGENY.SH"
date
echo "=========================================================================="
echo "Input dir:                       $indir"
echo "FASTQ file pattern:              $fastq_pattern"
echo "Refernece genome FASTA file:     $reference"
echo "Output dir:                      $outdir"
echo "Resume previous run:             $resume"
echo
echo "Nextflow workflow file:          $nextflow_file"
echo "Container dir:                   $container_dir"
echo "Scratch (work) dir:              $work_dir"
echo "Config 'profile':                $profile"
[[ "$more_args" != "" ]] && echo "Additional arguments:            $more_args"
[[ "$config_file" != "" ]] && echo "Config file:                     $config_file"
echo "=========================================================================="
echo


# MAIN -------------------------------------------------------------------------
if [[ "$debug" = false ]]; then
    ## Make necessary dirs
    mkdir -p "$work_dir" "$container_dir" "$outdir" "$trace_dir"

    ## Remove old trace files
    [[ -f "$trace_dir"/report.html ]] && rm "$trace_dir"/report.html
    [[ -f "$trace_dir"/trace.txt ]] && rm "$trace_dir"/trace.txt
    [[ -f "$trace_dir"/timeline.html ]] && rm "$trace_dir"/timeline.html
    [[ -f "$trace_dir"/dag.png ]] && rm "$trace_dir"/dag.png
fi

## Define the workflow run command
command="nextflow run $nextflow_file \
    --indir $indir \
    --outdir $outdir \
    --fastq_pattern '$fastq_pattern' \
    --reference $reference \
    --adapter_file $ADAPTER_FILE \
    --tree fasttree \
    --full_output \
    -work-dir $work_dir \
    -ansi-log false \
    -with-report $trace_dir/report.html \
    -with-trace $trace_dir/trace.txt \
    -with-timeline $trace_dir/timeline.html \
    -with-dag $trace_dir/dag.png \
    -profile $profile \
    $config_arg \
    $resume_arg \
    $more_args"

#TODO Different tree building program --tree arg ?

#? - Note that the docs say the adapter argument is 'adapter_sequences', but it is actually 'adapter_file'
#? - Note that the docs say the reference argument is 'reference_sequence', but it is actually 'reference'

## Run the workflow
echo "## Starting the workflow using the following command:"
echo
echo "$command" | tr -s " "
echo
[[ "$debug" = false ]] && eval $command


# WRAP UP ----------------------------------------------------------------------
echo -e "\n-------------------------------"
if [[ "$debug" = false ]]; then
    echo "## Listing files in the output dir:"
    ls -lh "$outdir"
    echo
    sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
    echo
fi
echo "## Done with script"
date
echo
