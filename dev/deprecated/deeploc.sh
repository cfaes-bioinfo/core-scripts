#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=deeploc
#SBATCH --output=slurm-deeploc-%j.out

#!NOTE: This script runs version 2.0 of Deeploc.
#!      There is a version 2.1 which seems to have significant improvements,
#!      but is available only as a webserver: https://services.healthtech.dtu.dk/services/DeepLoc-2.1/
#!      See also https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11223819/

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "                        RUN DEEPLOC2"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -i <input FASTA> -o <output dir> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile     <file>  Input file: protein FASTA (proteome)"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --model         <str>   DeepLoc2 model: 'Accurate' or 'Fast'        [default: 'Accurate']"
    echo "  --more_args     <str>   Quoted string with additional argument(s) to pass to DeepLoc"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for DeepLoc and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i results/braker/proteome.fa -o results/deeploc"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - Online server: https://services.healthtech.dtu.dk/service.php?DeepLoc-2.0"
    echo "  - Paper: https://academic.oup.com/nar/advance-article/doi/10.1093/nar/gkac278/6576357"
    echo
}

# Load software
Load_software() {
    set +u
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/deeploc
    set -u
}

# Print help for the focal program
Print_help_program() {
    Load_software
    deeploc2 --help
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
    date
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
# Option defaults
model=Accurate

debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
infile=""
outdir=""
more_args=""

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --model )           shift && model=$1 ;;
        --more_args )       shift && more_args=$1 ;;
        -h )                Print_help; exit 0 ;;
        --help )            Print_help_program; exit 0;;
        --dryrun )          dryrun=true && e="echo ";;
        --debug )           debug=true ;;
        * )                 Die "Invalid option $1" "$all_args" ;;
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

# Load software
[[ "$dryrun" = false ]] && Load_software

# Check input
[[ "$infile" = "" ]] && Die "Please specify an input file with -i/--infile" "$all_args"
[[ "$outdir" = "" ]] && Die "Please specify an output dir with -o/--outdir" "$all_args"
[[ ! -f "$infile" ]] && Die "Input file $infile does not exist"

# Report
echo
echo "=========================================================================="
echo "                    STARTING SCRIPT DEEPLOC.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Input file:                       $infile"
echo "Output dir:                       $outdir"
echo "Run model:                        $model"
[[ $more_args != "" ]] && echo "Other arguments for DeepLoc:      $more_args"
echo
echo "Listing the input file(s):"
ls -lh "$infile"
[[ $dryrun = true ]] && echo -e "\nTHIS IS A DRY-RUN"
echo "=========================================================================="

# Print reserved resources
[[ "$slurm" = true ]] && Print_resources


# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output directory
echo -e "\n# Creating the output directories..."
${e}mkdir -pv "$outdir"/logs

# Run
echo -e "\n# Now running DeepLoc..."
${e}Time \
    deeploc2 \
    --fasta "$infile" \
    --output "$outdir" \
    --model "$model" \
    $more_args


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    echo "# Listing files in the output dir:"
    ls -lhd "$PWD"/"$outdir"/*
    [[ "$slurm" = true ]] && Resource_usage
fi
echo "# Done with script"
date
echo
