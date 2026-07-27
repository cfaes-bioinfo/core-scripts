#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=15
#SBATCH --mem=100G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=braker2
#SBATCH --output=slurm-braker2-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "                  RUN BRAKER2 WITH REFERENCE PROTEINS"
    echo "======================================================================"
    echo
    echo "NOTE: If you have RNAseq-data to aid annotation, use the 'braker3.sh' script instead!"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -i <input FASTA> -o <outdir> --species <species_name> --ref_prot <FASTA file> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--assembly   <file>  Input assembly nucleotide FASTA"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo "  --species       <str>   Species name (without space, e.g. 'homo_sapiens')"
    echo "  --ref_prot      <file>  FASTA with reference proteins. For info on how to create this file:"
    echo "                          https://github.com/gatech-genemark/ProtHint#protein-database-preparation"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_args     <str>   Quoted string with additional argument(s) to pass to Braker"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for Braker and exit"
    echo "  -v/--version            Print the version of Braker and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i results/genome.fa -o results/braker --ref_prot data/ref/proteins.faa --species homo_sapiens"
    echo "  sbatch $0 -i results/genome.fa -o results/braker --ref_prot data/ref/proteins.faa --species homo_sapiens --more_args '--fungus'"
    echo
    echo "HARDCODED PARAMETERS:"
    echo "  - '--softmasked'        The script assumes that genome repeats have been soft-masked"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - Docs: https://github.com/Gaius-Augustus/BRAKER"
    echo "  - Paper: https://academic.oup.com/nargab/article/3/1/lqaa108/6066535"
    echo
}

# Load software
Load_software() {
    set +u
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    
    # Braker2 conda env which contains everything except GeneMark-EX and ProtHint
    CONDA_DIR=/fs/ess/PAS0471/jelmer/conda/braker2-env
    source activate "$CONDA_DIR"

    # Remove config file for species, if it exists
    # Otherwise, Braker will complain unless you use '--useexisting', but config may need to be updated...
    [[ -d "$CONDA_DIR"/config/species/"$species" ]] && rm -rv "$CONDA_DIR"/config/species/"$species"
    
    # GeneMark-EX
    # See https://github.com/Gaius-Augustus/BRAKER#genemark-ex
    GENEMARK_BASEDIR=/fs/ess/PAS0471/jelmer/software/genemark-ex
    export GENEMARK_PATH="$GENEMARK_BASEDIR"/gmes_linux_64_4
    cp "$GENEMARK_BASEDIR"/gm_key_64 ~/.gm_key

    # See https://github.com/Gaius-Augustus/BRAKER#prothint
    export PROTHINT_PATH=/fs/ess/PAS0471/jelmer/software/ProtHint/bin
    export PYTHON3_PATH=/fs/ess/PAS0471/jelmer/conda/braker2-env/bin

    set -u
}

# Print version
Print_version() {
    set +e
    Load_software
    braker.pl --version
    set -e
}

# Print help for the focal program
Print_help_program() {
    Load_software
    braker.pl --help
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
debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
assembly=""
ref_prot=""
species=""
outdir=""
more_args=""

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --assembly )   shift && assembly=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --species )         shift && species=$1 ;;
        --ref_prot )        shift && ref_prot=$1 ;;
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

# Strict bash settings
set -euo pipefail

# Load software and set nr of threads
[[ "$dryrun" = false ]] && Load_software
Set_threads

# Check input
[[ "$assembly" = "" ]] && Die "Please specify an input file with -i/--assembly" "$all_args"
[[ "$ref_prot" = "" ]] && Die "Please specify an input file with --ref_prot" "$all_args"
[[ "$species" = "" ]] && Die "Please specify a species name with --species" "$all_args"
[[ "$outdir" = "" ]] && Die "Please specify an output dir with -o/--outdir" "$all_args"
[[ ! -f "$assembly" ]] && Die "Input file $assembly does not exist"
[[ ! -f "$ref_prot" ]] && Die "Input file $ref_prot does not exist"

# If needed, make dirs absolute because we have to move into the outdir
[[ ! $assembly =~ ^/ ]] && assembly=$(realpath "$assembly")
[[ ! $ref_prot =~ ^/ ]] && ref_prot=$(realpath "$ref_prot")

# Report
echo
echo "=========================================================================="
echo "                    STARTING SCRIPT BRAKER2.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Output dir:                       $outdir"
echo "Input file:                       $assembly"
echo "Reference protein FASTA:          $ref_prot"
echo "Species:                          $species"
[[ $more_args != "" ]] && echo "Other arguments for Braker:       $more_args"
echo "Number of threads/cores:          $threads"
echo
echo "Listing the input file(s):"
ls -lh "$assembly" "$ref_prot"
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

# Move into the output dir
cd "$outdir" || exit 1

# Run
echo -e "\n# Now running Braker..."
${e}Time \
    braker.pl \
    --genome="$assembly" \
    --prot_seq="$ref_prot" \
    --species="$species" \
    --softmasking \
    --verbosity=3 \
    --cores="$threads" \
    $more_args

# Used options:
# --softmasking         Softmasking option for soft masked genome               

# Other useful options:
#  --gff3               Output a GFF3 instead of a GTF file
#  --fungus             GeneMark-EX option: run algorithm with branch point model
#                       (most useful for fungal genomes)
#  --useexisting        Use the present config and parameter files if they exist for 'species'; 
#                       will overwrite original parameters if BRAKER performs an AUGUSTUS training.



# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    echo "# Version used:"
    Print_version | tee logs/version.txt
    echo -e "\n# Listing files in the output dir:"
    ls -lhd "$PWD"/braker/*
    [[ "$slurm" = true ]] && Resource_usage
fi
echo "# Done with script"
date
echo
