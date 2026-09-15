#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=80G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=gubbins
#SBATCH --output=slurm-gubbins-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Gubbins to remove HGT among a bacterial genome alignment, and create a phylogenetic tree"
MODULE=miniconda3
CONDA=/fs/ess/PAS0471/jelmer/conda/gubbins
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY=run_gubbins.py
TOOL_NAME=Gubbins
TOOL_DOCS=http://nickjcroucher.github.io/gubbins/
VERSION_COMMAND="$TOOL_BINARY --version"

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
    echo "      sbatch $0 -i results/snippy/core.full.aln -o results/gubbins"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--alignment  <file>  Input alignment in FASTA format"
    echo "  -o/--outdir     <str>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --out_prefix    <file>  Output prefix                               [default: basename of input alignment file]"
    echo "  --dates         <file>  Dates file for dating"
    echo "  --start_tree    <file>  Tree file to serve as a starting tree"
    echo "  --more_args     <str>   Quoted string with additional argument(s) for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help               Print this help message and exit"
    echo "  -v                      Print the version of this script and exit"
    echo "  --version               Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION:"
    echo "  - $TOOL_DOCS"
    echo "  - Tutorial:         https://github.com/nickjcroucher/gubbins/blob/master/docs/gubbins_tutorial.md "
    echo "  - Manual:           https://github.com/nickjcroucher/gubbins/blob/master/docs/gubbins_manual.md "
    echo "  - Repository:       https://github.com/nickjcroucher/gubbins "
    echo "  - Paper:            https://academic.oup.com/nar/article/43/3/e15/2410982 "
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
infile=
tree= && tree_arg=
date_file= && date_arg=
out_prefix=
outdir=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --alignment )  shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --out_prefix )      shift && out_prefix=$1 ;;
        --dates )           shift && date_file=$1 ;;
        --start_tree )      shift && tree=$1 ;;
        --more_args )       shift && more_args=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         load_env "$MODULE" "$CONDA"
                            print_version "$VERSION_COMMAND" && exit 0 ;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check arguments
[[ -z "$infile" ]] && die "No input alignment file specified, do so with -i/--alignment" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -f "$infile" ]] && die "Input alignment file $infile does not exist"
[[ -n "$tree" && ! -f "$tree" ]] && die "Input file $tree does not exist"
[[ -n "$date_file" && ! -f "$date_file" ]] && die "Input file $tree does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Logging files and dirs
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
VERSION_FILE="$LOG_DIR"/version.txt
CONDA_YML="$LOG_DIR"/conda_env.yml
ENV_FILE="$LOG_DIR"/env.txt

# Load software and set nr of threads
load_env "$MODULE" "$CONDA" "$CONDA_YML"
set_threads "$IS_SLURM"

# Make paths absolute
infile=$(realpath "$infile")
[[ -n $tree ]] && tree=$(realpath "$tree")
[[ -n $date_file ]] && date_file=$(realpath "$date_file")

# Build tree and dates arguments
[[ -n $tree ]] && tree_arg="--starting-tree $tree"
[[ -n $date_file ]] && date_arg="--date $date_file"

# Output prefix
[[ -z "$out_prefix" ]] && out_prefix=$(basename "${infile%.*}")
out_prefix_full="$outdir"/"$out_prefix"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options/arguments passed to this script:  $all_args"
echo "Alignment input file:                         $infile"
echo "Output dir:                                   $outdir"
echo "Output file prefix:                           $out_prefix"
[[ -n "$tree" ]] && echo "Starting tree input file:                     $tree"
[[ -n "$date_file" ]] && echo "Dates input file:                             $date_file"
[[ -n $more_args ]] && echo "Additional arguments for $TOOL_NAME:          $more_args"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Move into the outdir because Gubbins will produce tempfiles in the working dir
cd "$outdir" || die "Cannot change working dir to $outdir"

# Run the tool
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --threads "$threads" \
    --prefix "$out_prefix_full" \
    $date_arg \
    $tree_arg \
    "$infile" \
    $more_args

# List the output, report version, etc
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$VERSION_COMMAND" "$VERSION_FILE" "$ENV_FILE" "$IS_SLURM" \
    "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL"
