#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=panaroo
#SBATCH --output=slurm-panaroo-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run a pangenome analysis with Panaroo and align core genes"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=panaroo
TOOL_NAME=Panaroo
TOOL_DOCS=https://gtonkinhill.github.io/panaroo
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                           # 'conda' or 'container'
conda_path=
container_path=/fs/ess/PAS0471/containers/depot.galaxyproject.org-singularity-panaroo-1.3.3--pyhdfd78af_0.img
container_url=https://depot.galaxyproject.org/singularity/panaroo:1.3.3--pyhdfd78af_0
dl_container=false
container_dir="$HOME/containers"
version_only=false

# Constants - tool parameters
ALIGN_THESE=core            # Align 'core' or 'pan' (all genes); Panaroo's '--alignment' argument
REMOVE_INVALID_OPT="--remove-invalid-genes"

# Defaults - tool parameters
mode=strict                 # Use Panaroo's 'strict' mode by default (Panaroo has no default for this)
core_threshold=0.95         # Same as Panaroo's default

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 --i results/prokka -o results/panaroo"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <file>  Input dir with Prokka or Bakta GFF files ('.gff' or '.gff3' extension)"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --clean_mode        <str>   Panaroo's running mode: 'strict', 'moderate', or 'sensitive' [default: 'strict']"
    echo "  --core_threshold    <num>   Core-genome sample threshold            [default=0.95]"
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or --dl_container is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: false]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "HARDCODED PANAROO OPTIONS:"
    echo "  - The script always uses '--alignment core' to only align core genes"
    echo "  - The script always uses '--remove-invalid-genes' to remove invalid genes"
    echo "      (Otherwise it fails on some GFF files, especially from Bakta)"
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

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
indir=
outdir=
more_opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --clean_mode )      shift && mode=$1 ;;
        --core_threshold )  shift && core_threshold=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
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
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$indir" ]] && die "No input file specified, do so with -i/--indir" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
mapfile -t gffs < <(find "$indir" -iname '*.gff' -or -iname '*.gff3')
[[ ${#gffs[@]} -eq 0 ]] && die "No GFF files found in $indir..."

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:            $all_opts"
echo "Input dir:                                    $indir"
echo "Number of GFF files:                          ${#gffs[@]}"
echo "Output dir:                                   $outdir"
echo "Panaroo mode:                                 $mode"
echo "Align 'pan' or 'core' genes:                  $ALIGN_THESE" 
echo "Core gene threshold:                          $core_threshold"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:            $more_opts"
log_time "Listing the input file(s):"
ls -lh "${gffs[@]}"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -o "$outdir" \
    --clean-mode "$mode" \
    --core_threshold "$core_threshold" \
    --alignment "$ALIGN_THESE" \
    $REMOVE_INVALID_OPT \
    --threads "$threads" \
    -i "${gffs[@]}" \
    $more_opts

#? Other Panaroo options
#> --aligner Options:'prank', 'clustal', and default: 'mafft'

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
