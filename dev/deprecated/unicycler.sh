#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=30G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=unicycler
#SBATCH --output=slurm-unicycler-%j.out

#! 2023-07-19
#! NOTE -- UniCycler crashes when trying to use multiple cores
#!         I think this is because of its weird/wrong specification of memory for Spades
#!         I tried adding '-spades_options "--memory 32"' but this doesn't replace the other specification

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run UniCycler to assemble a bacterial isolate genome with PE Illumina reads
Note that the defaults are set up for a short-read only assembly"
MODULE=miniconda3
CONDA=/fs/ess/PAS0471/jelmer/conda/unicycler
SCRIPT_VERSION="2023-07-15"
SCRIPT_AUTHOR="Jelmer Poelstra"
SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY=unicycler
TOOL_NAME=UniCycler
TOOL_DOCS=https://github.com/rrwick/Unicycler
VERSION_COMMAND="$TOOL_BINARY --version"

# Constants
UNPAIRED_SUFFIX="_unpaired"     # Unpaired FASTQ files are assumed to have this suffix

# Parameter defaults
use_unpaired=true               # Look for and use corresponding FASTQ file with unpaired reads
contig_size_arg=                # Use UniCycler's default by default

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
    echo "      sbatch $0 -i data/sampleA_R1.fastq.gz -o results/unicycler"
    echo "  - Use '--more_args' as follows:"
    echo "      sbatch $0 -i data/sampleA_R1.fastq.gz -o results/unicycler --more_args '--mode bold'"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1         <file>  Input R1 FASTQ file"
    echo "                            The script will look for corresponding R2 ('_2' or '_R2') and unpaired ('_unpaired') FASTQs"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --min_contig_size <int> Minimum contig size: filter out smaller ones after assembly"
    echo "                          This is UniCycler's '--min_fasta_length' argument; default is to use Unicycler's default, currently 100 bp"
    echo "  --no_unpaired           Don't look for a FASTQ file with unpaired reads"
    echo "  --more_args     <str>   Quoted string with additional argument(s) for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help               Print this help message and exit"
    echo "  -v                      Print the version of this script and exit"
    echo "  --version               Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION:"
    echo "  - $TOOL_DOCS"
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
R1=
outdir=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --no_unpaired )     use_unpaired=false ;;
        --min_contig_size ) shift && min_contig_size=$1 ;;
        --more_args )       shift && more_args=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         load_env "$MODULE" "$CONDA"
                            print_version "$VERSION_COMMAND" && exit 0 ;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check arguments
[[ -z "$R1" ]] && die "No input file specified, do so with -i/--R1" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -f "$R1" ]] && die "Input file $R1 does not exist"

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

# Get R2 filename
file_ext=$(basename "$R1" | sed -E 's/.*(.fasta|.fastq.gz|.fq.gz)$/\1/')
R1_suffix=$(basename "$R1" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
R2_suffix=${R1_suffix/1/2}
R2=${R1/$R1_suffix/$R2_suffix}
[[ ! -f "$R2" ]] && die "Input file $R2 does not exist"

# Get unpaired filename
if [[ "$use_unpaired" == true ]]; then
    unpaired=${R1/$R1_suffix/$UNPAIRED_SUFFIX}
    [[ ! -f "$unpaired" ]] && die "Input file $unpaired does not exist"
    unpaired_arg="-s $unpaired"
else
    unpaired_arg=
fi

# Min contig size argument
[[ -n "$min_contig_size" ]] && contig_size_arg="--min_fasta_length $min_contig_size"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options/arguments passed to this script:  $all_args"
echo "Input R1 FASTQ file:                          $R1"
echo "Input R2 FASTQ file:                          $R2"
[[ "$use_unpaired" == true ]] && echo "Input unpaired FASTQ file:                    $unpaired"
echo "Output dir:                                   $outdir"
[[ -n "$min_contig_size" ]] && echo "Min. contig size:                             $min_contig_size"
[[ -n $more_args ]] && echo "Additional arguments for $TOOL_NAME:          $more_args"
log_time "Listing the input file(s):"
ls -lh "$R1" "$R2"
[[ "$use_unpaired" == true ]] && ls -lh "$unpaired"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Run the tool
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -1 "$R1" \
    -2 "$R2" \
    $unpaired_arg \
    $contig_size_arg \
    -o "$outdir" \
    --threads "$threads" \
    $more_args

#? --mode {conservative,normal,bold}

# List the output, report version, etc
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$VERSION_COMMAND" "$VERSION_FILE" "$ENV_FILE" "$IS_SLURM" \
    "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL"
