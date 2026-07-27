#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=72:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --job-name=smartdenovo
#SBATCH --output=slurm-smartdenovo-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
function Print_help() {
    echo
    echo "==========================================================================="
    echo "              $0: Run SmartDenovo to assemble a genome"
    echo "==========================================================================="
    echo
    echo "USAGE:"
    echo "  sbatch $0 [ -i <input FASTQ(s)> | -I <fofn> ] -o <output FASTA> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -o/--outfile    <str>   Output assembly FASTA file (use extension '.fa' or '.fasta')"
    echo "To specify the input, use one of the two following options:"
    echo "  -i/--reads      <file>  An input FASTQ file"
    echo "                          Or optionally multiple files, quoted and space-separated"
    echo "  --fofn          <file>  Text file with list of input FASTQ files one per line (fofn)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --readlen       <int>   Minimum read length, shorter reads will be removed     [default: 5000]"
    echo "  --more_args     <str>   Other argument(s) to pass to SmartDenovo"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for Smartdenovo and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i \"data/fastq/A.fq.gz data/fastq/B.fq.gz\" -o results/smartdenovo/sus_scrofa.fasta"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - https://github.com/ruanjue/smartdenovo "
    echo
}

# Load software
Load_software() {
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/smartdenovo-env
}

# Print help for the focal program
Print_help_program() {
    Load_software
    smartdenovo.pl --help
}

# Print SLURM job resource usage info
Resource_usage() {
    sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%60,Elapsed,CPUTime | grep -Ev "ba|ex"
}

# Print SLURM job requested resources
Print_resources() {
    set +u
    echo "# SLURM job information:"
    echo "Account (project):    $SLURM_JOB_ACCOUNT"
    echo "Job ID:               $SLURM_JOB_ID"
    echo "Job name:             $SLURM_JOB_NAME"
    echo "Memory (MB per node): $SLURM_MEM_PER_NODE"
    echo "CPUs per task:        $SLURM_CPUS_PER_TASK"
    [[ "$SLURM_NTASKS" != 1 ]] && echo "Nr of tasks:          $SLURM_NTASKS"
    [[ -n "$SBATCH_TIMELIMIT" ]] && echo "Time limit:           $SBATCH_TIMELIMIT"
    echo "======================================================================"
    echo
    set -u
}

# Set the number of threads/CPUs
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
# Option defaults
min_readlen=5000

debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
declare -a infiles
fofn=""
outfile=""
more_args=""

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --reads )          shift && IFS=" " read -r -a infiles <<< "$1" ;;
        -I | --fofn )           shift && fofn=$1 ;;
        -o | --assembly )       shift && outfile=$1 ;;
        --readlen )             shift && min_readlen=$1 ;;
        --more_args )           shift && more_args=$1 ;;
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
# In debugging mode, print all commands
[[ "$debug" = true ]] && set -o xtrace

# Check if this is a SLURM job
[[ -z "$SLURM_JOB_ID" ]] && slurm=false

# Load software and set nr of threads
[[ "$dryrun" = false ]] && Load_software
Set_threads

# Bash strict settings
set -euo pipefail

# Check input
[[ ${#infiles[@]} = 0 && "$fofn" = "" ]] && Die "Please specify input files with -i or -I" "$all_args"
[[ $outfile = "" ]] && Die "Please specify an output prefix with -o" "$all_args"

# Define prefix and output dir
outdir=$(dirname "$outfile")
file_ext=$(echo "$outfile" | sed -E 's/.*(.fasta|.fna|.fa)$/\1/')
out_prefix=${outfile/"$file_ext"/}

# If a FOFN was provided, read file list into an array
[[ "$fofn" != "" ]] && mapfile -t infiles <"$fofn"

# Report
echo "=========================================================================="
echo "                    STARTING SCRIPT SMARTDENOVO.SH"
date
echo "=========================================================================="
echo "All arguments to this script:         $all_args"
[[ "$fofn" != "" ]] && echo "File with list of FASTQs (fofn):      $fofn"
echo "Input files:                          ${infiles[*]}"
echo "Number of input files:                ${#infiles[*]}"
echo "Output file:                          $outfile"
echo "Minimum read length:                  $min_readlen"
[[ $more_args != "" ]] && echo "Other arguments for Smartdenovo:      $more_args"
echo
echo "# Listing the input files:"
for infile in "${infiles[@]}"; do
    [[ ! -f $infile ]] && Die "Input file $infile does not exist!"
    ls -lh "$infile"
done
[[ $dryrun = true ]] && echo -e "\nTHIS IS A DRY-RUN"
echo "=========================================================================="

# Print reserved resources
[[ "$slurm" = true ]] && Print_resources


# ==============================================================================
#                               RUN
# ==============================================================================
if [[ "$dryrun" = false ]]; then

    # Create output dir
    echo -e "\n# Creating the output directories..."
    mkdir -pv "$outdir"/logs

    # Concatenate FASTQ files if needed
    if [[ ${#infiles[*]} -gt 1 ]]; then
        infile_final="$outdir"/concat_input.fastq.gz
        echo -e "\n# Concatenating input files..."
        cat "${infiles[@]}" > "$infile_final"
        ls -lh "$infile_final"
    else
        infile_final=${infiles[0]}
    fi
    echo "Final input file:                     $infile_final"

    # Generate a Makefile for smartdenovo to run
    echo -e "\n# Generating a Makefile for Smartdenovo..."
    Time smartdenovo.pl \
        -p "$out_prefix" \
        -t "$threads" \
        -c 1 \
        -J "$min_readlen" \
        "$infile_final" \
        > "$out_prefix".mak

    echo -e "\n# Generated the following Makefile:"
    ls -lh "$out_prefix".mak
    echo
    cat -n "$out_prefix".mak
    echo

    #? "After assembly, the raw unitigs are reported in file prefix.lay.utg and consensus unitigs in prefix.cns"
    #? -c 1 => make consensus
    #? -J = min read length -- default = 5,000

    # Run SmartDenovo by running the Makefile
    echo -e "\n# Running Smartdenovo..."
    Time make -f "$out_prefix".mak

    # Copy assembly FASTA
    echo -e "\n# Copying the assembly FASTA file:"
    cp -v "$out_prefix".dmo.cns "$outfile"

fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    echo -e "\n# Listing the final assembly file:"
    ls -lhd "$PWD"/"$outfile"
    echo
    [[ "$slurm" = true ]] && Resource_usage
    echo
fi
echo "# Done with script"
date
