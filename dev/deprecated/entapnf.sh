#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=120:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=entapnf
#SBATCH --output=slurm-entapnf-%j.out

#TODO -- Include new parameters in the nfcore-schema thing
#TODO -- Make options for taxon name and contaminants

#? The ext.args line for interproscan in modules.config that included 'PANTHER' was commented out -- why? I included it and it seems to work fine

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "================================================================================"
    echo "                        $0"
    echo "             Run the TRanscriptome AsseMbly (tram) Nextflow workflow"
    echo "================================================================================"
    echo "REQUIRED OPTIONS:"
    echo "  -i/--assembly   <file>  Input assembly in FASTA format"
    echo "  -o/--outdir     <dir>   Output directory for workflow results"
    echo "  --taxid         <str>   NCBI Taxon ID number"
    echo
    echo "INPUT DATABASE OPTIONS:"
    echo "#TODO"
    echo
    echo "OTHER INPUT DATA OPTIONS:"
    echo "  --seq_type      <int>   Specifies if the input FASTA file is 'nuc' for nucleotide or 'pep' for protein. [default: pep]"
    echo "  --entap_config  <file>  Initial EnTap config file"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "--qcoverage, --tcoverage, --sensitivity + ADD contaminants and taxon name #TODO"
    echo "  --batch_size    <int>   Number of transcripts to run at a time"
    echo "  --more_args     <str>   Quoted string with additional arguments to pass to 'nextflow run'"
    echo
    echo "NEXTFLOW-RELATED OPTIONS:"
    echo "  -nf             <file>  Nextflow workflow definition file                       [default: 'workflows/nf-transcriptome-assembly/main.nf']"
    echo "  -restart                Don't attempt to resume workflow run, but start over    [default: resume]"
    echo "  -profile        <str>   Profile from any of the config files to use             [default: 'conda,normal']"
    echo "  -ctn-dir        <dir>   Singularity container dir                               [default: '/fs/ess/PAS0471/containers']"
    echo "                            - This is where any containers used in the workflow will be downloaded to"
    echo "  -work-dir       <dir>   Scratch (work) dir for the workflow                     [default: Nextflow default = 'work']"
    echo "                            - This is where the workflow results will be stored before final results are copied to the specified output dir"
    echo "                            - This should preferable be a dir in OSC's scratch dir rather than in the main project dir"
    echo "  -config         <file>  Additional config file                                  [default: none]"
    echo "                            - Settings in this file will override default settings"
    echo "                            - Note that the mcic-scripts OSC config file will always be included, too"
    echo "                              (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  -ansi-log"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the Nextflow workflow's help and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i data/fastq -o results/tram"
}

# Load the software
Load_software() {
    set +u

    # Load OSC's Conda module
    module load miniconda3/4.12.0-py39

    # Activate the Nextflow Conda environment
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/nextflow

    ## Singularity container dir - any downloaded containers will be stored here
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    # Limit memory for Nextflow main process - see https://www.nextflow.io/blog/2021/5_tips_for_hpc_users.html
    export NXF_OPTS='-Xms1g -Xmx4g'

    set -u
}

# Print help for the focal program
Print_help_program() {
    Load_software
    nextflow run "$nf_file" --help
}

# Print SLURM job resource usage info
Resource_usage() {
    echo
    sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%60,Elapsed,CPUTime | grep -Ev "ba|ex"
    echo
}

# Print SLURM job requested resources
Print_resources() {
    set +u
    echo "# SLURM job information:"
    echo "Account (project):    $SLURM_JOB_ACCOUNT"
    echo "Job ID:               $SLURM_JOB_ID"
    echo "Job name:             $SLURM_JOB_NAME"
    echo "Memory (MB per node): $SLURM_MEM_PER_NODE"
    echo "CPUs (per task):      $SLURM_CPUS_PER_TASK"
    [[ "$SLURM_NTASKS" != 1 ]] && echo "Nr of tasks:          $SLURM_NTASKS"
    [[ -n "$SBATCH_TIMELIMIT" ]] && echo "Time limit:           $SBATCH_TIMELIMIT"
    echo "======================================================================"
    echo
    set -u
}

# Resource usage information
Time() {
    /usr/bin/time -f \
        '\n# Ran the command:\n%C \n\n# Run stats by /usr/bin/time:\nTime: %E   CPU: %P    Max mem: %M K    Exit status: %x \n' \
        "$@"
}   

# Exit upon error with a message
Die() {
    error_message=${1}
    error_args=${2-none}
    
    echo >&2
    echo "=====================================================================" >&2
    printf "$0: ERROR: %s\n" "$error_message" >&2
    echo -e "\nFor help, run this script with the '-h' option" >&2
    echo "For example, 'bash mcic-scripts/qc/fastqc.sh -h'" >&2
    if [[ "$error_args" != "none" ]]; then
        echo -e "\nArguments passed to the script:" >&2
        echo "$error_args" >&2
    fi
    echo -e "\nEXITING..." >&2
    echo "=====================================================================" >&2
    echo >&2
    exit 1
}

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# URL to OSC Nextflow config file
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
osc_config=mcic-scripts/nextflow/osc.config  # Will be downloaded if not present here

# Option defaults
seq_type="nuc"          # Specifies if the input FASTA file is "nuc" for nucleotide or "pep" for protein. [default: pep]
batch_size=5            # Run 'batch_size' transcripts at a time

nf_file="systemsgenetics/entapnf"
container_dir=/fs/ess/PAS0471/containers
profile="singularity"
resume=true && resume_arg="-resume"
ansi_log=false && ansi_log_arg="-ansi-log false"
use_downloaded_config=false

debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
assembly=""
outdir=""
taxid=""
entap_config=""

qcoverage="" && qcoverage_arg=""     # Use the workflow's default (50)
tcoverage="" && tcoverage_arg=""     # Use the workflow's default (50)
sensitivity="" && sensitivity_arg="" # Use the workflow's default (--more-sensitive)

ipr_dir="" && ipr_arg=""
nr_diamond="" && nr_arg=""
refseq_diamond="" && refseq_arg=""
sprot_diamond="" && sprot_arg=""
orthodb_diamond="" && orthodb_arg=""
custom_diamond="" && custom_arg=""
string_diamond="" && string_arg=""

config_file_extra="" && config_arg=""
work_dir="" && work_dir_arg=""
more_args=""

# Parse command-line options
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -nf )                   shift && nf_file=$1 ;;
        -i | --assembly )       shift && assembly=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --entap_config )        shift && entap_config=$1 ;;
        --qcoverage )           shift && qcoverage=$1 ;;
        --tcoverage )           shift && tcoverage=$1 ;;
        --sensitivity )         shift && sensitivity=$1 ;;
        --taxid )               shift && taxid=$1 ;;
        --seq_type )            shift && seq_type=$1 ;;
        --data_ipr )            shift && ipr_dir=$1 ;;
        --data_nr )             shift && nr_diamond=$1 ;;
        --data_refseq )         shift && refseq_diamond=$1 ;;
        --data_sprot )          shift && sprot_diamond=$1 ;;
        --data_string )         shift && string_diamond=$1 ;;
        --data_orthodb )        shift && orthodb_diamond=$1 ;;
        --data_custom )         shift && custom_diamond=$1 ;;
        --batch_size )          shift && batch_size=$1 ;;
        --more_args )           shift && more_args=$1 ;;
        -cnt-dir)               shift && container_dir=$1 ;;
        -config )               shift && config_file_extra=$1 ;;
        -profile )              shift && profile=$1 ;;
        -work-dir )             shift && work_dir=$1 ;;
        -ansi-log )             ansi_log=true ;;
        -restart )              resume=false ;;
        --debug )               debug=true ;;
        --dryrun )              dryrun=true && e="echo ";;
        -h )                    Print_help; exit ;;
        --help )                Print_help_workflow; exit ;;
        * )                     Die "Invalid option $1" "$all_args" ;;
    esac
    shift
done


# ==============================================================================
#                          OTHER SETUP
# ==============================================================================
# In debugging mode, print all commands
[[ "$debug" = true ]] && set -o xtrace

# Check if this is a SLURM job
[[ -z "$SLURM_JOB_ID" ]] && slurm=false

# Bash script settings
set -euo pipefail

# Load software and set nr of threads
[[ "$dryrun" = false ]] && Load_software

# Check input
[[ "$assembly" = "" ]] && Die "Please specify an input assembly file with -i/--assembly" "$all_args"
[[ "$outdir" = "" ]] && Die "Please specify an output dir with -o/--outdir" "$all_args"
[[ ! -f "$assembly" ]] && Die "Input file $assembly does not exist"

# Build the config argument
if [[ ! -f "$osc_config" ]]; then
    use_downloaded_config=true
    osc_config="$outdir"/$(basename "$OSC_CONFIG_URL")
fi
config_arg="-c $osc_config"

# Add extra config file, if it was provided
[[ "$config_file_extra" != "" ]] && config_arg="$config_arg -c ${config_file_extra/,/ -c }"

# Define trace output dir
trace_dir="$outdir"/pipeline_info

# Build other Nextflow arguments
[[ "$resume" = false ]] && resume_arg=""
[[ "$work_dir" != "" ]] && work_dir_arg="-work-dir $work_dir"
[[ "$ansi_log" = true ]] && ansi_log_arg=""

[[ "$qcoverage" != "" ]] && qcoverage_arg="--qcoverage $qcoverage"
[[ "$tcoverage" != "" ]] && tcoverage_arg="--tcoverage $tcoverage"
[[ "$sensitivity" != "" ]] && sensitivity_arg="--sensitivity $sensitivity"

# Database locations
enzyme_dat="$sprot_diamond"/enzyme.dat

[[ "$ipr_dir" != "" ]] && ipr_arg="--data_ipr $ipr_dir"
[[ "$sprot_diamond" != "" ]] && sprot_arg="--data_sprot $sprot_diamond --enzyme_dat $enzyme_dat"
[[ "$refseq_diamond" != "" ]] && refseq_arg="--data_refseq $refseq_diamond"
[[ "$string_diamond" != "" ]] && string_arg="--data_string $string_diamond"
[[ "$orthodb_diamond" != "" ]] && orthodb_arg="--data_orthodb $orthodb_diamond"
[[ "$nr_diamond" != "" ]] && nr_arg="--data_nr $nr_diamond"
[[ "$custom_diamond" != "" ]] && custom_arg="--data_custom $custom_diamond"

# Check input
[[ "$ipr_dir" != "" && ! -d "$ipr_dir" ]] && Die "Database dir $ipr_dir does not exist" #TODO change to file
[[ "$nr_diamond" != "" && ! -d "$nr_diamond" ]] && Die "Database dir $nr_diamond does not exist"
[[ "$refseq_diamond" != "" && ! -d "$refseq_diamond" ]] && Die "Database dir $refseq_diamond does not exist"
[[ "$sprot_diamond" != "" && ! -d "$sprot_diamond" ]] && Die "Database dir $sprot_diamond does not exist"
[[ "$string_diamond" != "" && ! -d "$string_diamond" ]] && Die "Database dir $string_diamond does not exist"
[[ "$orthodb_diamond" != "" && ! -d "$orthodb_diamond" ]] && Die "Database dir $orthodb_diamond does not exist"
[[ "$sprot_diamond" != "" && ! -f "$enzyme_dat" ]] && Die "Database file $enzyme_dat does not exist"
[[ "$custom_diamond" != "" && ! -f "$custom_diamond" ]] && Die "Database file $custom_diamond does not exist"


# Report
echo
echo "=========================================================================="
echo "                   STARTING SCRIPT ENTAPNF.SH"
date
echo "=========================================================================="
echo "All arguments passed to this script: $all_args"
echo
echo "INPUT/OUTPUT DATA OPTIONS:"
echo "  Output dir:                     $outdir"
echo "  Input assembly FASTA:           $assembly"
echo "  (Number of genes:               $(grep -c "^>" "$assembly"))"
echo
echo "RUN SETTINGS:"
echo "  Taxon ID:                       $taxid"
echo "  EnTap config file:              $entap_config"
echo "  Assembly sequence type:         $seq_type"
echo "  Batch size:                     $batch_size"
[[ "$qcoverage" != "" ]] && echo "  Min. query coverage:            $qcoverage"
[[ "$tcoverage" != "" ]] && echo "  Min. target (subject) coverage: $tcoverage"
[[ "$sensitivity" != "" ]] && echo "  DIAMOND sensitivity:            $sensitivity"
[[ "$more_args" != "" ]] && echo "  Additional arguments:            $more_args"
echo
echo "DATABASES:"
[[ "$ipr_dir" != "" ]] && echo "  Interpro:                       $ipr_dir" 
[[ "$nr_diamond" != "" ]] && echo "  NCBI NR:                        $nr_diamond"
[[ "$refseq_diamond" != "" ]] && echo "  RefSeq:                         $refseq_diamond"
[[ "$sprot_diamond" != "" ]] && echo "  Uniprot Sprot:                  $sprot_diamond"
[[ "$string_diamond" != "" ]] && echo "  STRING:                         $string_diamond"
[[ "$orthodb_diamond" != "" ]] && echo "  Interpro:                       $orthodb_diamond"
[[ "$custom_diamond" != "" ]] && echo "  Custom DB:                       $custom_diamond"
echo
echo "NEXTFLOW-RELATED OPTIONS:"
echo "  Resume previous run:            $resume"
echo "  Nextflow workflow file:         $nf_file"
echo "  Work (scratch) dir:             $work_dir"
echo "  Container dir:                  $container_dir"
echo "  Config 'profile':               $profile"
echo "  Config argument:                $config_arg"
[[ "$config_file_extra" != "" ]] && echo "  Additional config file:         $config_file_extra"
[[ $dryrun = true ]] && echo -e "\nTHIS IS A DRY-RUN"
echo "=========================================================================="
echo


# ==============================================================================
#                               RUN
# ==============================================================================
# Make necessary dirs
echo -e "\n# Creating the output directories..."
${e}mkdir -pv "$work_dir" "$container_dir" "$outdir"/logs "$trace_dir"

# Remove old trace files
[[ -f "$trace_dir"/report.html ]] && ${e}rm "$trace_dir"/report.html
[[ -f "$trace_dir"/trace.txt ]] && ${e}rm "$trace_dir"/trace.txt
[[ -f "$trace_dir"/timeline.html ]] && ${e}rm "$trace_dir"/timeline.html
[[ -f "$trace_dir"/dag.png ]] && ${e}rm "$trace_dir"/dag.png

# Get the OSC config file
if [[ "$use_downloaded_config" = true ]]; then
    echo -e "\n # Downloading the OSC config file..."
    wget -O "$osc_config" "$OSC_CONFIG_URL"
fi

# Run the workflow
echo -e "\n# Starting the workflow...\n"
${e}Time nextflow run \
    "$nf_file" \
    --input "$assembly" \
    --outdir "$outdir" \
    --seq_type "$seq_type" \
    --taxonomy_ID "$taxid" \
    --batch_size "$batch_size" \
    $qcoverage_arg \
    $tcoverage_arg \
    $sensitivity_arg \
    $ipr_arg \
    $sprot_arg \
    $refseq_arg \
    $string_arg \
    $orthodb_arg \
    $nr_arg \
    $custom_arg \
    --entap_config "$entap_config" \
    --igenomes_ignore \
    --publish_dir_mode "copy" \
    -with-report "$trace_dir"/report.html \
    -with-trace "$trace_dir"/trace.txt \
    -with-timeline "$trace_dir"/timeline.html \
    -with-dag "$trace_dir"/dag.png \
    -profile "$profile" \
    $work_dir_arg \
    $ansi_log_arg \
    $config_arg \
    $resume_arg \
    $more_args

#! Taxon ID doesn't seem to be used in the workflow - I specified the taxon name in the initial entap config file
#! Help says default publish mode is copy, but it seems to be 'link'?


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    [[ "$slurm" = true ]] && Resource_usage
fi
echo "# Done with script"
date

# ==============================================================================
#                               DATABASE SETUP
# ==============================================================================
# Refseq-Plant - https://github.com/SystemsGenetics/EnTAPnf/blob/master/scripts/get_ncbi_refseq.sh
    # - Downloaded to /fs/scratch/PAS0471/jelmer/dbs/refseq_plant
# InterProscan data - https://github.com/SystemsGenetics/EnTAPnf/blob/master/scripts/get_interpro.sh
# Uniprot Trembl - https://github.com/SystemsGenetics/EnTAPnf/blob/master/scripts/get_uniprot_trembl.sh
# UniProt Sprot + enzyme.dat - https://github.com/SystemsGenetics/EnTAPnf/blob/master/scripts/get_uniprot_swissprot.sh
# StringDB - https://github.com/SystemsGenetics/EnTAPnf/blob/master/scripts/get_string.sh
    # - Downloaded to /fs/scratch/PAS0471/jelmer/dbs/string
    # - Trying to run bin/index_string.py, but get 'NameError: name 'os' is not defined'
    # /fs/ess/PAS0471/jelmer/assist/2022-04_soumya/workflows/EnTAPnf/bin/index_string.py --links protein.links.full.v11.0.txt --info protein.info.v11.0.txt --out .
# OrthoDB - https://github.com/SystemsGenetics/EnTAPnf/blob/master/scripts/get_orthodb.sh
    # - Downloaded to /fs/scratch/PAS0471/jelmer/dbs/orthodb
    # - Also ran index_orthodb.py -- Index files are not used?!
# Dicots PLAZA download
#wget ftp://ftp.psb.ugent.be/pub/plaza/plaza_public_dicots_05/Fasta/proteome.all_transcripts.fasta.gz
#gunzip *gz
#proteome.all_transcripts.fasta > plaza_dicots5.faa

