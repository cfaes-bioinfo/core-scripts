#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=15
#SBATCH --mem=60G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=medaka_align
#SBATCH --output=slurm-medaka_align-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Medaka to polish a genome assembly with ONT reads.
Parallel edition - script 1 of 3"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=mini_align
TOOL_NAME=Medaka
TOOL_DOCS=https://github.com/nanoporetech/medaka
VERSION_COMMAND="medaka --version"

# Defaults - generics
env_type=container                           # Use a 'conda' env or a Singularity 'container'
conda_path=
container_path=oras://community.wave.seqera.io/library/medaka:2.2.2--93eb3c09ecc347a8
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
    echo "      sbatch $0 -i data/my.fastq -r results/assembly.fasta -o results/medaka"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  --reads             <file>  Input reads: FASTQ file (reads used for correction)"
    echo "  --assembly          <file>  Input assembly: FASTA file (to be corrected)"
    echo "  -o/--outdir         <dir>   Output dir for BAM file (will be created if needed)"
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
outdir=
reads=
assembly=
more_opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -o | --outdir )     shift && outdir=$1 ;;
        --reads )           shift && reads=$1 ;;
        --assembly )        shift && assembly=$1 ;;
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
[[ -z "$reads" ]] && die "No input reads file specified, do so with --reads" "$all_opts"
[[ -z "$assembly" ]] && die "No input assembly file specified, do so with --assembly" "$all_opts"
[[ -z "$outdir" ]] && die "No output file specified, do so with -o/--outfile" "$all_opts"
[[ ! -f "$reads" ]] && die "Input reads file $reads does not exist"
[[ ! -f "$assembly" ]] && die "Input reads file $assembly does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
prefix=$(basename "${assembly%.*}")

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input reads (FASTQ) file:                 $reads"
echo "Input assembly (FASTA) file:              $assembly"
echo "Output BAM file:                          $outdir/$prefix.bam"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$reads" "$assembly" 
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
        -i "$reads" \
        -r "$assembly" \
        -p "$outdir"/"$prefix" \
        -t "$threads" \
        -m \
        $more_opts

log_time "Listing the output file:"
ls -lh "$outdir"/"$prefix".bam
final_reporting "$LOG_DIR"
