#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --mem=48G
#SBATCH --cpus-per-task=12
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bowtie2
#SBATCH --output=slurm-bowtie2-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "      Run Bowtie2 to map FASTQ reads to a transcriptome assembly"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -i <input assembly> [ --fq_dir <dir> --fq_fofn <fofn> ] -o <output BAM> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--assembly   <file>  Input transcriptome assembly FASTA file"
    echo "  --fq_dir <dir> OR --fq_fofn <file>  Input dir or FOFN (File Of File Names) with FASTQ files"
    echo "  -o/--bam        <file>  Output BAM file"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more-args     <str>   Quoted string with additional argument(s) to pass to Bowtie2"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for Bowtie2 and exit"
    echo "  -v/--version            Print the version of Bowtie2 and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i results/assembly.fa --fq_dir data/fastq/ -o results/bowtie2"
    echo
    echo "HARDCODED PARAMETERS:"
    echo "  - The script assumes that the FASTQ reads are paired-end"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - Docs: https://bowtie-bio.sourceforge.net/bowtie2/index.shtml"
    echo
}

# Load software
Load_software() {
    set +u
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/bowtie2-2.5.0 # Also includes samtools
    set -u
}

# Print version
Print_version() {
    Load_software
    bowtie2 --version
}

# Print help for the focal program
Print_help_program() {
    Load_software
    bowtie2 --help
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
debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
assembly=""
fq_dir=""
fq_fofn=""
bam=""
more_args=""

# Parse command-line args
all_args="$*"

while [ "$1" != "" ]; do
    case "$1" in
        -i | --assembly )   shift && assembly=$1 ;;
        --fq_dir )          shift && fq_dir=$1 ;;
        --fq_fofn )         shift && fq_fofn=$1 ;;
        -o | --bam )        shift && bam=$1 ;;
        --more-args )       shift && more_args=$1 ;;
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

# Load software and set nr of threads
[[ "$dryrun" = false ]] && Load_software
Set_threads

# Other parameters
outdir=$(dirname "$bam")
file_ext=$(basename "$assembly" | sed -E 's/.*(.fasta|.fa|.fna)$/\1/')
assembly_id="$outdir"/$(basename "$assembly" "$file_ext")

# Create lists with input files
if [[ "$fq_dir" != "" ]]; then
    [[ ! -d "$fq_dir" ]] && Die "Input FASTQ dir $fq_dir does not exist"
    R1_list=$(echo "$fq_dir"/*R1*fastq.gz | sed 's/ /,/g')
    R2_list=$(echo "$fq_dir"/*R2*fastq.gz | sed 's/ /,/g')
elif [[ "$fq_fofn" != "" ]]; then
    [[ ! -f "$fq_fofn" ]] && Die "Input FOFN $fq_fofn does not exist"
    R1_list=$(grep "_R1" "$fq_fofn" | tr "\n" "," | sed 's/,$/\n/')
    R2_list=$(grep "_R2" "$fq_fofn" | tr "\n" "," | sed 's/,$/\n/')
else
    Die "Please specify FASTQ input with --fq_dir or --fq_fofn"
fi

# Input files
[[ "$fq_fofn" != "" ]] && mapfile -t fq_files <"$fq_fofn"
[[ "$fq_dir" != "" ]] && mapfile -t fq_files < <(find "$fq_dir" -type f -name "*fastq.gz")

# Check input
[[ "$assembly" = "" ]] && Die "Please specify an input assembly with -i/--assembly"
[[ "$bam" = "" ]] && Die "Please specify an output BAM file with -o/--bam"
[[ ! -f "$assembly" ]] && Die "Input assembly file $assembly does not exist"

# Report
echo
echo "=========================================================================="
echo "                    STARTING SCRIPT BOWTIE2.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Input assembly:                   $assembly"
echo "Input FASTQ dir:                  $fq_dir"
echo "Output BAM file:                  $bam"
[[ $more_args != "" ]] && echo "Other arguments for Bowtie:     $more_args"
echo "Number of threads/cores:          $threads"
echo
echo "List of R1 files:                 $R1_list"
echo "List of R2 files:                 $R2_list"
echo "Listing the input FASTQ file(s):"
ls -lh "${fq_files[@]}"
[[ $dryrun = true ]] && echo -e "\nTHIS IS A DRY-RUN"
echo "=========================================================================="

# Print reserved resources
[[ "$slurm" = true ]] && Print_resources


# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output directory
${e}mkdir -p "$outdir"/logs

echo -e "\nIndexing the transcriptome..."
bowtie2-build \
    --threads "$threads" \
    "$assembly" \
    "$outdir"/"$assembly_id"

# MAP READS --------------------------------------------------------------------
echo -e "\n# Starting Bowtie2 mapping..."
bowtie2 \
    -p "$threads" \
    --no-unal \
    -k 20 \
    -x "$outdir"/"$assembly_id" \
    -1 "$R1_list" \
    -2 "$R2_list" \
    $more_args |
    samtools view -@"$threads" --bam --output "$bam"

#? Parameter settings from https://github.com/trinityrnaseq/trinityrnaseq/wiki/RNA-Seq-Read-Representation-by-Trinity-Assembly


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

