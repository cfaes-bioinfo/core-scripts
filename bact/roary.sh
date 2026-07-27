#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=roary
#SBATCH --output=slurm-roary-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Roary for a pangenome analysis"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=roary
TOOL_NAME=Roary
TOOL_DOCS=https://sanger-pathogens.github.io/Roary
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                       # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=https://depot.galaxyproject.org/singularity/roary:3.13.0--pl526h516909a_0
container_path=
dl_container=false
container_dir="$HOME/containers"

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
    echo "      sbatch $0 -i results/prokka -o results/roary"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <file>  Input dir with Prokka or Bakta GFF files ('.gff' or '.gff3' extension)"
    echo "  -o/--outdir         <dir>   Output dir (NOTE: this dir should not yet exist)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or '--dl_container' is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
    echo
}

# Function to source the script with Bash functions
source_function_script() {
    # Determine the location of this script, and based on that, the function script
    if [[ "$IS_SLURM" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script=$(realpath "$script_dir"/../dev/"$(basename "$FUNCTION_SCRIPT_URL")")
    # Download the function script if needed, then source it
    if [[ ! -f "$function_script" ]]; then
        echo "Can't find script with Bash functions ($function_script), downloading from GitHub..."
        function_script=$(basename "$FUNCTION_SCRIPT_URL")
        wget "$FUNCTION_SCRIPT_URL" -O "$function_script"
    fi
    source "$function_script"
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
opts=
version_only=false
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --opts )            shift && opts=$1 ;;
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
[[ -z "$indir" ]] && die "No input file specified, do so with -i/--indir" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"
[[ -d "$outdir" ]] && die "Outdir $outdir already exists, please remove or rename it"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mapfile -t gffs < <(find "$indir" -iname '*.gff' -or -iname '*.gff3')
[[ ${#gffs[@]} -eq 0 ]] && die "No GFF files found in $indir..."

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input dir:                                $indir"
echo "Output dir:                               $outdir"
echo "Number of GFF files:                      ${#gffs[@]}"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "${gffs[@]}"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -f "$outdir" \
    -e -n \
    -p "$threads" \
    $opts \
    -v "${gffs[@]}"

#? -e Creates a multiFASTA alignment of core genes
#? -n aligns core genes with MAFFT

# Make the log dir afterwards, or Roary would have used another outdir
mkdir -p "$LOG_DIR"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
