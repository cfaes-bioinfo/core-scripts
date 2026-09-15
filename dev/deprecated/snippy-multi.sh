#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=snippy
#SBATCH --output=slurm-snippy-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run snippy-multi to align FASTQ files for multiple samples
to a reference genome and find SNPs"
MODULE=miniconda3
CONDA=/fs/ess/PAS0471/jelmer/conda/snippy-4.6.0
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY=snippy-multi
TOOL_NAME=Snippy
TOOL_DOCS=https://github.com/tseemann/snippy
VERSION_COMMAND="snippy --version"

# Constants - parameters
#TODO

# Parameter defaults
#TODO

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo
    echo "        $0 (v. $SCRIPT_VERSION): Run $TOOL_NAME"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i snippy_input.tsv -o results/snippy --ref results/assemblies/genomeA.fasta"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--input_table    file>   Input TSV with paths to FASTQ files"
    echo "                              Should have 3 columns (no header): genome ID, forward reads FASTQ, reverse reads FASTQ"
    echo "  -r/--ref            <file>  Input reference genome FASTA or Genbank file"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_args         <str>   Quoted string with additional argument(s) for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
    echo
}

# Function to source the script with Bash functions
source_function_script() {
    # NOTE: the argument is optional - some call sites pass none and rely on
    #       the IS_SLURM global instead
    local is_slurm=${1:-${IS_SLURM:-false}} candidate

    # Determine the location of this script, and based on that, the function script
    if [[ "$is_slurm" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"

    # Look for a local copy first, in order of preference, and only download as a
    # last resort: the download writes into the working dir, which many jobs share
    for candidate in "$script_dir"/../dev/"$function_script_name" \
                     "$script_dir"/../core-scripts/dev/"$function_script_name" \
                     "$function_script_name"; do
        if [[ -s "$candidate" ]]; then
            source "$candidate"
            check_functions_loaded
            return 0
        fi
    done

    # Download to a temp file, then move into place, so that concurrent jobs
    # can never source a half-written file
    echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
    tmp_script=$(mktemp "$function_script_name".XXXXXX)
    if ! wget -q "$FUNCTION_SCRIPT_URL" -O "$tmp_script"; then
        rm -f "$tmp_script"
        echo "ERROR: Failed to download $FUNCTION_SCRIPT_URL" >&2
        exit 1
    fi
    mv -f "$tmp_script" "$function_script_name"
    source "$function_script_name"
    check_functions_loaded
}

# Make sure the function script really provided the functions we rely on
check_functions_loaded() {
    if ! declare -F log_time check_val die load_env >/dev/null; then
        echo "ERROR: Sourced $function_script_name but its functions are missing" >&2
        echo "       (an outdated or truncated copy may be in the way - try deleting it)" >&2
        exit 1
    fi
}

# ==============================================================================
#                          INFRASTRUCTURE SETUP I
# ==============================================================================
# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
input_table=
ref=
outdir=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --input_table )    shift && input_table=$1 ;;
        -r | --ref )            shift && ref=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --more_args )           shift && more_args=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version )             load_env "$MODULE" "$CONDA"
                                print_version "$VERSION_COMMAND" && exit 0 ;;
        * )                     die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check arguments
[[ -z "$input_table" ]] && die "No input table specified, do so with -i/--input_table" "$all_args"
[[ -z "$ref" ]] && die "No input reference specified, do so with -i/--ref" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -f "$input_table" ]] && die "Input file $input_table does not exist"
[[ ! -f "$ref" ]] && die "Input file $ref does not exist"


# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Logging files and dirs
LOG_DIR="$outdir"/logs
VERSION_FILE="$LOG_DIR"/version.txt
CONDA_YML="$LOG_DIR"/conda_env.yml
ENV_FILE="$LOG_DIR"/env.txt
mkdir -p "$LOG_DIR"

# Load software and set nr of threads
load_env "$MODULE" "$CONDA" "$CONDA_YML"
set_threads "$IS_SLURM"

# Make path to reference absolute
[[ ! "$ref" =~ ^/ ]] && ref=$(realpath "$ref")

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options/arguments passed to this script:  $all_args"
echo "Input TSV with paths to FASTQ files:          $input_table"
echo "Reference genome file:                        $ref"
echo "Output dir:                                   $outdir"
[[ -n $more_args ]] && echo "Additional arguments for $TOOL_NAME:          $more_args"
log_time "Listing the input file(s):"
ls -lh "$input_table" "$ref"
log_time "Showing the contents of the input table file:"
cat -n "$input_table"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Run the tool
log_time "Generating Snippy commands with snippy-multi..."
$TOOL_BINARY \
    "$input_table" \
    --ref "$ref" \
    --cpus "$threads" \
    --force \
    $more_args \
    > "$outdir"/runme.sh

log_time "Showing the contents of the generated runme.sh file:"
cat -n "$outdir"/runme.sh

log_time "Now running Snippy..."
cd "$outdir" || exit 1
runstats bash runme.sh
cd -

# List the output, report version, etc
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$VERSION_COMMAND" "$VERSION_FILE" "$ENV_FILE" "$IS_SLURM" \
    "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL"

# ==============================================================================
#                               NOTES
# ==============================================================================
# I was getting SnpEff errors when trying to run with Genbank input
# (SnpEff is only run when the input is GenBank and not FASTA)
# See <https://github.com/tseemann/snippy/issues/259?_blank>
# and <https://www.mail-archive.com/debian-bugs-dist@lists.debian.org/msg1890116.html>
# Based on the latter link, I downgraded snpEff to v5.0 and that worked!
# micromamba install -c bioconda snpeff=5.0
