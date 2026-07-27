#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=30
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=medaka_collate
#SBATCH --output=slurm-medaka_collate-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Medaka to polish a genome assembly with ONT reads.
Parallel edition - script 3 of 3"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="medaka sequence"
TOOL_NAME=Medaka
TOOL_DOCS=https://github.com/nanoporetech/medaka
VERSION_COMMAND="medaka --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=oras://community.wave.seqera.io/library/medaka:2.2.2--93eb3c09ecc347a8
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
version_only=false                 # When true, just print tool & script version info and exit

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
    echo "  - Basic usage example:"
    echo "      sbatch $0 -i results/medaka/inf -o results/medaka/asm.fasta"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--assembly_in    <file>  Input assembly FASTA file"
    echo "  --hdf_dir           <file>  Input dir with HDF files from medaka_2_inf.sh"
    echo "  -o/--assembly_out   <file>  Output assembly FASTA file (dir will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "                                (NOTE: If no default '--container_url' is listed below,"
    echo "                                 you'll have to provide one in order to run the script with a container.)"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or '--dl_container' is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
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
        wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script"
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
hdf_dir=
assembly_in=
assembly_out=
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --assembly_in )   shift && assembly_in=$1 ;;
        --hdf_dir )             shift && hdf_dir=$1 ;;
        -o | --assembly_out )   shift && assembly_out=$1 ;;
        --more_opts )           shift && more_opts=$1 ;;
        --env_type )                 shift && env_type=$1 ;;
        --dl_container )        dl_container=true ;;
        --container_dir )       shift && container_dir=$1 ;;
        --container_url )       shift && container_url=$1 && dl_container=true ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version )             version_only=true ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
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
[[ -z "$assembly_in" ]] && die "No input assembly specified, do so with -i/assembly_in" "$all_opts"
[[ -z "$hdf_dir" ]] && die "No input dir specified, do so with --hdf_dir" "$all_opts"
[[ -z "$assembly_out" ]] && die "No output file specified, do so with -o/--assembly_out" "$all_opts"
[[ ! -d "$hdf_dir" ]] && die "Input dir $hdf_dir does not exist"
[[ ! -f "$assembly_in" ]] && die "Input file $assembly_in does not exist"

# Define outputs based on script parameters
outdir=$(dirname "$assembly_out")
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input assembly FASTA file:                $assembly_in"
echo "HDF dir:                                  $hdf_dir"
echo "Output assembly FASTA file:               $assembly_out"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$assembly_in" "$hdf_dir" 
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    "$hdf_dir"/*hdf \
    "$assembly_in" \
    "$assembly_out"

log_time "Listing the output file:"
ls -lh "$assembly_out"
final_reporting "$LOG_DIR"
