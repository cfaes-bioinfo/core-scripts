#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=32:00:00
#SBATCH --mem=40G
#SBATCH --cpus-per-task=10
#SBATCH --job-name=metataxa
#SBATCH --output=slurm-metaxa-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
## Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "             RUN METAXA TO EXTRACT rRNA SEQUENCES"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -i <input file> -o <output dir> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1_in      <file>  Input R1 FASTQ file (name of R2 file will be inferred)"
    echo "  -o/--outdir     <dir>   Base output dir (will be created if needed)"
    echo "                          Note: The results will be placed in a subdir derived from the filename"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_args     <str>   Quoted string with additional argument(s) to pass to Metaxa2"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for Metaxa2 and exit"
    echo "  -v/--version            Print the version of Metaxa2 and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i data/A1_R1.fastq.gz -o results/metaxa2"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - Docs: https://microbiology.se/publ/metaxa2_users_guide_2.2.pdf"
    echo "  - Paper: https://pubmed.ncbi.nlm.nih.gov/25732605/"
    echo
}

## Load software
Load_software() {
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate; done
    source activate /fs/ess/PAS0471/jelmer/conda/metaxa-2.2.3
}

## Print version
Print_version() {
    Load_software
    metaxa2 --version 2>&1 | head -n 3
}

## Print help for the focal program
Print_help_program() {
    Load_software
    metaxa2 --help
}

## Print SLURM job resource usage info
Resource_usage() {
    ${e}sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%60,Elapsed,CPUTime,MaxVMSize | \
        grep -Ev "ba|ex"
}

## Print SLURM job requested resources
Print_resources() {
    set +u
    echo "# SLURM job information:"
    echo "Account (project):    $SLURM_JOB_ACCOUNT"
    echo "Job ID:               $SLURM_JOB_ID"
    echo "Job name:             $SLURM_JOB_NAME"
    echo "Memory (per node):    $SLURM_MEM_PER_NODE"
    echo "CPUs per task:        $SLURM_CPUS_PER_TASK"
    [[ "$SLURM_NTASKS" != 1 ]] && echo "Nr of tasks:          $SLURM_NTASKS"
    [[ -n "$SBATCH_TIMELIMIT" ]] && echo "Time limit:           $SBATCH_TIMELIMIT"
    echo "======================================================================"
    echo
    set -u
}

## Set the number of threads/CPUs
Set_threads() {
    set +u
    if [[ "$slurm" = true ]]; then
        if [[ -n "$SLURM_CPUS_PER_TASK" ]]; then
            threads="$SLURM_CPUS_PER_TASK"
        elif [[ -n "$SLURM_NTASKS" ]]; then
            threads="$SLURM_NTASKS"
        else 
            echo "WARNING: Can't detect nr of threads, setting to 1"
            threads=1
        fi
    else
        threads=1
    fi
    set -u
}

## Resource usage information
Time() {
    /usr/bin/time -f \
        '\n# Ran the command:\n%C \n\n# Run stats by /usr/bin/time:\nTime: %E   CPU: %P    Max mem: %M K    Avg Mem: %t K    Exit status: %x \n' \
        "$@"
}   

## Exit upon error with a message
Die() {
    error_message=${1}
    error_args=${2-none}
    
    echo
    echo "====================================================================="
    printf "$0: ERROR: %s\n" "$error_message" >&2
    echo -e "\nFor help, run this script with the '-h' option"
    echo "For example, 'bash mcic-scripts/qc/fastqc.sh -h"
    if [[ "$error_args" != "none" ]]; then
        echo -e "\nArguments passed to the script:"
        echo "$error_args"
    fi
    echo -e "\nEXITING..." >&2
    echo "====================================================================="
    echo
    exit 1
}


# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
## Option defaults
debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
## Placeholder defaults
R1_in=""
outdir=""
more_args=""

## Parse command-line args
all_args="$*"

while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1_in )          shift && R1_in=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --more_args )           shift && more_args=$1 ;;
        -v | -v | --version )        Print_version; exit 0;;
        -h )                    Print_help; exit 0;;
        --help )                Print_help_program; exit 0;;
        --dryrun )              dryrun=true && e="echo ";;
        --debug )               debug=true ;;
        * )                     Die "Invalid option $1" "$all_args" ;;
    esac
    shift
done


# ==============================================================================
#                          OTHER SETUP
# ==============================================================================
## In debugging mode, print all commands
[[ "$debug" = true ]] && set -o xtrace

## Check if this is a SLURM job
[[ -z "$SLURM_JOB_ID" ]] && slurm=false

## Load software and set nr of threads
[[ "$dryrun" = false ]] && Load_software
Set_threads

## Bash script settings
set -euo pipefail

## Make path absolute
[[ ! "$R1_in" =~ ^/ ]] && R1_in="$PWD"/"$R1_in" 

## Infer name of R2 file and full output dir
file_ext=$(basename "$R1_in" | sed -E 's/.*(.fasta|.fastq.gz|.fq.gz)/\1/')
R1_suffix=$(basename "$R1_in" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
R2_suffix=${R1_suffix/1/2}
R2_in=${R1_in/$R1_suffix/$R2_suffix}
sample_id=$(basename "$R1_in" "$file_ext" | sed -E "s/${R1_suffix}_?[[:digit:]]*//")
outdir_full="$outdir"/"$sample_id"

## Report
echo
echo "=========================================================================="
echo "                    STARTING SCRIPT METAXA.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "R1 FASTQ file:                    $R1_in"
echo "Base output dir:                  $outdir"
echo "Full output dir:                  $outdir_full"
[[ $more_args != "" ]] && echo "Other arguments for Metaxa2: $more_args"
echo "Number of threads/cores:          $threads"
echo "R2 FASTQ file (inferred):         $R2_in"
echo
echo "Listing the input files:"
ls -lh "$R1_in" "$R2_in"
[[ $dryrun = true ]] && echo -e "\nTHIS IS A DRY-RUN"
echo "=========================================================================="

## Print reserved resources
[[ "$slurm" = true ]] && Print_resources

## Check input
[[ "$R1_in" = "" ]] && Die "Please specify an input file with -i/--infile" "$all_args"
[[ "$outdir" = "" ]] && Die "Please specify an output dir with -o/--outdir" "$all_args"
[[ ! -f "$R1_in" ]] && Die "Input file $R1_in does not exist"
[[ ! -f "$R2_in" ]] && Die "Input file $R2_in does not exist"
[[ "$R1_in" = "$R2_in" ]] && Die "Input file $R1_in and $R2_in are the same ($R1_in)"


# ==============================================================================
#                               RUN
# ==============================================================================
## Create the output dir
${e}mkdir -p "$outdir_full"/logs

## Move into the output dir
${e}cd "$outdir_full" || exit

echo -e "\n# Now running Metaxa2..."
${e}Time metaxa2 \
    -1 "$R1_in" \
    -2 "$R2_in" \
    -f p \
    -m metagenome \
    -o "$sample_id" \
    -t bacteria \
    --plus T \
    -cpu "$threads" $more_args

#--quality_trim T \ # It trims everything when this is on!


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    echo "# Version used:"
    Print_version | tee logs/version.txt
    echo -e "\n# Listing files in the output dir:"
    ls -lhd "$PWD"/*
    echo
    [[ "$slurm" = true ]] && Resource_usage
    echo
fi
echo "# Done with script"
date
