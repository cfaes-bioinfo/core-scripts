#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=36:00:00
#SBATCH --cpus-per-task=25
#SBATCH --mem=100G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=orna
#SBATCH --output=slurm-orna-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "   Run ORNA to normalize paired-end RNAseq reads prior to assembly"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 [ -i <input R1> | --fofn <fofn> ] -o <output dir> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1 <file> OR --fofn <file> Input R1 FASTQ file OR fofn (File Of File Names)"
    echo "                          When a FOFN is provided, R1 and R2 files will be concatenated separately" 
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --sorting_mode  <str>   ORNA sorting mode, either 'quality' (ORNA-Q) or 'abundance' (ORNA-K) [default: none]"
    echo "                          See https://github.com/SchulzLab/ORNA#enhancements-to-orna for details"
    echo "  --R2            <file>  Input R2 FASTQ file                         [default: infer from R1 name]"
    echo "  --more_args     <str>   Quoted string with additional argument(s) to pass to ORNA"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for ORNA and exit"
    echo "  -v/--version            Print the version of ORNA and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i data/A1_R1.fastq.gz -o results/orna"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - Docs: https://github.com/SchulzLab/ORNA"
    echo "  - Paper: https://www.nature.com/articles/s41598-019-41502-9"
    echo
}

# Load software
Load_software() {
    set +u
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate  2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/orna-2.0
    set -u
}

# Print version
Print_version() {
    set +e
    Load_software
    ORNA -version
    set -e
}

# Print help for the focal program
Print_help_program() {
    Load_software
    ORNA -help
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
sorting_mode="" && sorting_arg=""

debug=false
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
R1_in=""
R2_in=""
fofn=""
outdir=""
more_args=""

# Parse command-line args
all_args="$*"

while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1_in=$1 ;;
        --R2 )              shift && R2_in=$1 ;;
        --fofn )            shift && fofn=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --sorting_mode )    shift && sorting_mode=$1 ;;
        --more_args )       shift && more_args=$1 ;;
        -v | -v | --version )    Print_version; exit 0 ;;
        -h )                Print_help; exit 0 ;;
        --help )            Print_help_program; exit 0;;
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

# Load software and set nr of threads
Load_software
Set_threads

# Bash script settings
set -euo pipefail

# Input check I
[[ "$R1_in" = "" && "$fofn" = "" ]] && Die "Please specify input with --R1 or --fofn"
[[ "$outdir" = "" ]] && Die "Please specify an output dir with -o/--outdir" "$all_args"

# Determine output prefix
if [[ "$R1_in" != "" ]]; then
    [[ ! -f "$R1_in" ]] && Die "Input file $R1_in does not exist"
    R1_basename=$(basename "$R1_in" | sed -E 's/.fa?s?t?q.gz//')
    R1_suffix=$(echo "$R1_in" | sed -E 's/.*(_R?1).*fa?s?t?q.gz/\1/')
    sampleID=${R1_basename/"$R1_suffix"/}
else
    sampleID=$(basename "$fofn" .txt)
fi

# Determine name of R2 file
if [[ "$R1_in" != "" && "$R2_in" = "" ]]; then
    R2_suffix=${R1_suffix/1/2}
    R2_in=${R1_in/$R1_suffix/$R2_suffix}
    [[ ! -f "$R2_in" ]] && Die "Input file $R2_in does not exist"
    [[ "$R1_in" = "$R2_in" ]] && Die "Input files R1 and R2 are the same file: $R1_in"
fi

# Set sorting mode
if [[ $sorting_mode = "quality" ]]; then
    sorting_arg="-sorting 1"
elif [[ $sorting_mode = "abundance" ]]; then
    sorting_arg="-ksorting 1"
else
    sorting_arg=""
fi

# Report
echo
echo "=========================================================================="
echo "                    STARTING SCRIPT ORNA.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Output dir:                       $outdir"
[[ $sorting_mode != "" ]] && echo "Sorting mode:                     $sorting_mode"
[[ $sorting_arg != "" ]] && echo "Sorting mode argument:            $sorting_arg"
echo "Sample ID:                        $sampleID"
echo "Number of threads/cores:          $threads"
[[ $more_args != "" ]] && echo "Other arguments for Orna:         $more_args"
if [[ "$fofn" != "" ]]; then
    echo "FOFN:                             $fofn"
    echo "Number of input files:            $(grep -c . "$fofn")"
    echo "# Listing the input files:"
    cat "$fofn" | xargs -I{} ls -lh {}
fi
echo "=========================================================================="

# Print reserved resources
[[ "$slurm" = true ]] && Print_resources


# ==============================================================================
#                               RUN
# ==============================================================================
# Create output dir if needed
mkdir -p "$outdir"/logs

# Concatenate FASTQ files if a FOFN was provided
if [[ "$fofn" != "" ]]; then
    echo -e "\n# Now concatenating the FASTQ files..."
    R1_in="$outdir"/"$sampleID"_R1_concat.fastq.gz
    R2_in="$outdir"/"$sampleID"_R2_concat.fastq.gz
    grep "_R1" "$fofn" | xargs -I{} cat {} > "$R1_in"
    grep "_R2" "$fofn" | xargs -I{} cat {} > "$R2_in"
fi

# Report part 2
echo "R1 input file:                    $R1_in"
echo "R2 input file:                    $R2_in"
echo "Listing the input file(s):"
ls -lh "$R1_in" "$R2_in"
echo "=========================================================================="

# If needed, make paths absolute because we have to move into the outdir
[[ ! $R1_in =~ ^/ ]] && R1_in="$PWD"/"$R1_in"
[[ ! $R2_in =~ ^/ ]] && R2_in="$PWD"/"$R2_in"

# Move into the output dir
cd "$outdir" || exit

echo -e "\n# Starting normalization ..."
Time ORNA \
    -pair1 "$R1_in" \
    -pair2 "$R2_in" \
    -output "$sampleID" \
    -type fastq \
    -nb-cores "$threads" \
    $sorting_arg \
    $more_args

#? Apparently nb-cores does not work for PE mode? See https://github.com/SchulzLab/ORNA#orna-parameters

# Rename and gzip output files
echo -e "\n# Compressing the output FASTQ files..."
gzip -cv "$sampleID"_1.fq > "$sampleID"_R1.fastq.gz && rm "$sampleID"_1.fq
gzip -cv "$sampleID"_2.fq > "$sampleID"_R2.fastq.gz && rm "$sampleID"_2.fq
rm "$sampleID"*h5

# Counting nr of reads in the in- and output files
echo -e "\n# Counting the nr of reads in the in- and output files..."
nreads_in=$(zcat "$R1_in" | awk '{s++}END{print s/4}')
nreads_out=$(zcat "$sampleID"_R1.fastq.gz | awk '{s++}END{print s/4}')
echo "# Nr of reads in input: $nreads_in / nr of reads in output: $nreads_out"

# Removing the concatenated input files
echo -e "\n# Removing the concatenated input files..."
rm -v "$R1_in" "$R2_in"


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
echo "# Version used:"
Print_version | tee logs/version.txt
echo -e "\n# Listing files in the output dir:"
ls -lhd "$PWD"/*
[[ "$slurm" = true ]] && Resource_usage
echo "# Done with script"
date
