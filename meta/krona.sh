#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=krona
#SBATCH --output=slurm-krona-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Make Krona plots from Kraken output"
SCRIPT_VERSION="2024-09-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=ktImportTaxonomy
TOOL_NAME=Krona
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/krona
version_only=false                 # When true, just print tool & script version info and exit

# Defaults - software options
update_tax=false
tax_opt=

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/kraken/sampleA_main.txt -o results/krona"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input file: Kraken main output file with per-read results"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  -o/--outdir         <dir>   Output dir (default is same as indir; dir will be created if needed)"
    echo "  --update_tax                Update taxonomy prior to running Krona  [default: don't update]" 
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
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

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
infile=
outdir=
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --update_tax )      update_tax=true ;;
        --more_opts )       shift && more_opts=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$conda_path"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
[[ -z "$outdir" ]] && outdir=$(dirname "$infile")
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
outfile="$outdir"/$(basename "${infile%.*}").html
if [[ $update_tax == true ]]; then
    taxfile="$outdir"/taxonomy.tab
    tax_opt="-tax $taxfile"
fi
#taxfile="$conda_path"/opt/krona/taxonomy/taxonomy.tab

# Test
[[ "$infile" == "$outfile" ]] && die "Input and output files have the same name: $infile"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input file:                               $infile"
echo "Output file:                              $outfile"
echo "Update taxonomy first?                    $update_tax"
[[ $update_tax == true ]] && echo "Taxonomy file:                            $taxfile"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
if [[ "$update_tax" == true ]]; then
    log_time "Updating the taxonomy $TOOL_NAME..."
    runstats "$conda_path"/opt/krona/updateTaxonomy.sh "$taxfile"
    log_time "Taxonomy file:"
    ls -lh "$taxfile"
fi

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -q 2 \
    -t 3 \
    -o "$outfile" \
    $tax_opt \
    $more_opts \
    "$infile"

#? [-q <integer>]   Column of input files to use as query ID. Required if magnitude files are specified. [Default: '1']
#? [-t <integer>]   Column of input files to use as taxonomy ID. [Default: '2']

# Remove the dir with unneccessary files
find "$outdir" -type d -wholename "${outfile}.files" -print0 | xargs --null rm -r

# Final logging
log_time "Listing the HTML output file:"
ls -lh "$outfile"
final_reporting "$LOG_DIR"
