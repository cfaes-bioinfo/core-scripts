#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=effectorp
#SBATCH --output=slurm-effectorp-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "     RUN EFFECTORP 3.0 TO DETECT EFFECTORS IN FUNGI AND OOMYCETES"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -i <input FASTA> -o <output dir> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile     <file>  Input file: protein FASTA (secretome)"
    echo "                          Run EffectorP on secreted proteins only, as IDed with SignalP and (Deep)TMHMM"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --fungal_mode           Run EffectorP in fungal mode ('-f' option)  [default: off => oomycete mode]"
    echo "  --more_args     <str>   Quoted string with additional argument(s) to pass to EffectorP"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for EffectorP and exit"
    echo "  -v/--version            Print the version of EffectorP and exit"
    echo
    echo "OUTPUT:"
    echo "  - A tab-delimited table with predictions to <outdir>/..."
    echo "  - A FASTA with predicted effectors to <outdir>/..."
    echo "  - A FASTA with predicted non-effectors to <outdir>/..."
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i results/braker/proteome.fa -o results/effectorP"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - Docs: https://github.com/fteufel/signalp-6.0/blob/main/installation_instructions.md"
    echo "  - Paper: https://apsjournals.apsnet.org/doi/10.1094/MPMI-08-21-0201-R"
    echo
}

# Load software
Load_software() {
    EFFECTOR_P=/fs/ess/PAS0471/jelmer/software/EffectorP-3.0/EffectorP.py
}

# Print version
Print_version() {
    set +e
    Load_software
    python "$EFFECTOR_P" --help | sed -n 3p
    set -e
}

# Print help for the focal program
Print_help_program() {
    Load_software
    python "$EFFECTOR_P" --help
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
fungal_mode=false && fungal_arg=""

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
        --fungal_mode )     fungal_mode=true ;;
        --more_args )       shift && more_args=$1 ;;
        -v | -v | --version )    Print_version; exit 0 ;;
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

# Fungal mode arg
[[ "$fungal_mode" = true ]] && fungal_arg="-f"

# Define output files
table_out="$outdir"/table.txt
effector_fa="$outdir"/effectors.fa
noneffector_fa="$outdir"/noneffectors.fa

# Report
echo
echo "=========================================================================="
echo "                   STARTING SCRIPT EFFECTORP.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Input file:                       $infile"
echo "Output dir:                       $outdir"
[[ $more_args != "" ]] && echo "Other arguments for EffectorP:    $more_args"
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
echo -e "\n# Now running EffectorP..."
${e}Time \
    python "$EFFECTOR_P" \
    -i "$infile" \
    -o "$table_out" \
    -E "$effector_fa" \
    -N "$noneffector_fa" \
    $fungal_arg \
    $more_args


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    echo "# Version used:"
    Print_version | tee "$outdir"/logs/version.txt
    echo -e "\n# Listing files in the output dir:"
    ls -lhd "$PWD"/"$outdir"/*
    [[ "$slurm" = true ]] && Resource_usage
fi
echo "# Done with script"
date
echo
