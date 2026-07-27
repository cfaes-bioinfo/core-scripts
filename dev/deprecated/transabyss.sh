#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=48:00:00
#SBATCH --cpus-per-task=12
#SBATCH --mem=100G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=transabyss
#SBATCH --output=slurm-transabyss-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "           Run Trans-ABySS to create a transcriptome assembly"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 [ --indir <dir> | --fofn <fofn> ] --outdir <dir> --id <assemblyID> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir <dir> OR --fofn <dir>  Input dir OR a FOFN (File Of File Names)"
    echo "  -o/--outfile        <file>  Output assembly FASTA file"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --kmer_size         <int>   Kmer size"
    echo "  --min_contig_length <int>   Minimum contig length                   [default: 100]"
    echo "  --strandedness      <str>   Either 'stranded'/'reverse'/'forward' (all treated the same) or 'unstranded' [default: 'stranded']"
    echo "  --more_args         <str>   Quoted string with additional argument(s) to pass to Trans-ABySS"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                    Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                     Run the script in debug mode (print all code)"
    echo "  -h                          Print this help message and exit"
    echo "  --help                      Print the help for Trans-ABySS and exit"
    echo "  -v/--version                Print the version of Trans-ABySS and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i data/fastq -o results/transabyss --id kmer31 --kmer_size 31"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - Docs: https://github.com/bcgsc/transabyss/blob/master/TUTORIAL.md"
    echo
}

# Load software
Load_software() {
    set +u
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/transabyss-2.0.1
    set -u

    #? NOTE about the Conda environment
    #? To avoid warnings about a missing Makefile, I made it executable:
    #? chmod +x /fs/ess/PAS0471/jelmer/conda/transabyss-2.0.1/bin/abyss-pe.Makefile
    #? See https://github.com/bcgsc/transabyss/issues/26
}

# Print version
Print_version() {
    set +e
    Load_software
    transabyss --version
    set -e
}

# Print help for the focal program
Print_help_program() {
    Load_software
    transabyss --help
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
    echo "Memory (per node):    $SLURM_MEM_PER_NODE"
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
# Option defaults
kmer_size=32
min_contig_length=300
strandedness=reverse

debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
strand_arg=""
indir=""
fofn=""
declare -a infiles
outfile=""
more_args=""

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )          shift && indir=$1 ;;
        --fofn )                shift && fofn=$1 ;;
        -o | --outfile )        shift && outfile=$1 ;;
        --strandedness )        shift && strandedness=$1 ;;
        --kmer_size )           shift && kmer_size=$1 ;;
        --min_contig_length )   shift && min_contig_length=$1 ;;
        --more_args )           shift && more_args=$1 ;;
        -v | -v | --version )        Print_version; exit 0 ;;
        -h )                    Print_help; exit 0 ;;
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

# Bash script settings
set -euo pipefail

# Load software and set nr of threads
[[ "$dryrun" = false ]] && Load_software
Set_threads

# Infer outdir and assembly ID
outdir=$(dirname "$outfile")
outfile_name=$(basename "$outfile")
assembly_id=${outfile_name%.*}

# Get the input files
[[ "$fofn" != "" ]] && mapfile -t infiles <"$fofn"
[[ "$indir" != "" ]] && mapfile -t infiles < <(find "$indir" -type f -name "*fastq.gz") 

# Library type
if [[ "$strandedness" = "reverse" || "$strandedness" = "forward" || "$strandedness" = "stranded" ]]; then
    strand_arg="--SS"
fi

# Check input
[[ "$outfile" = "" ]] && Die "Please provide an output file with -o/--outfile"
[[ "$fofn" = "" && "$indir" = "" ]] && Die "Please provide input with -i/--indir or --fofn"

# Report
echo
echo "=========================================================================="
echo "                    STARTING SCRIPT TRANSABYSS.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
[[ "$indir" != "" ]] && echo "Input dir:                        $indir"
[[ "$fofn" != "" ]] && echo "FOFN:                             $fofn"
echo "Output assembly file:             $outfile"
echo "Kmer size:                        $kmer_size"
echo "Min contig length:                $min_contig_length"
echo "Strandedness / strand argument:   $strandedness / $strand_arg"
[[ $more_args != "" ]] && echo "Other arguments for Trans-ABySS:  $more_args"
echo "Number of threads/cores:          $threads"
echo "Number of input files:            ${#infiles[@]}"
echo "Listing the input file(s):"
ls -lh "${infiles[@]}"
echo "=========================================================================="

# Print reserved resources
[[ "$slurm" = true ]] && Print_resources


# ==============================================================================
#                               RUN
# ==============================================================================
# Make output dir(s)
echo -e "\n# Creating the output directories..."
${e}mkdir -pv "$outdir"/logs

# Run Trans-ABySS
echo -e "\n# Running Trans-ABySS..."
${e}Time transabyss \
    --pe "${infiles[@]}" \
    --kmer "$kmer_size" \
    --length "$min_contig_length" \
    --threads "$threads" \
    --outdir "$outdir" \
    --name "$assembly_id" \
    $strand_arg \
    $more_args

# Copy the assembly
echo -e "\n# Copying the final assembly file..."
${e}cp -v "$outdir"/"$assembly_id"-final.fa "$outfile"


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    echo "# Version used:"
    Print_version | tee "$outdir"/logs/version.txt
    echo -e "\n# Listing the final output assembly:"
    ls -lh "$PWD"/"$outfile"
    [[ "$slurm" = true ]] && Resource_usage
fi
echo "# Done with script"
date
