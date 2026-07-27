#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=30
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=abricate
#SBATCH --output=slurm-abricate-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run ABRicate to screen bacterial genome assemblues for antimicrobial and virulence genes
The output file will have the same name as the input fasta, with the extension switched to '.tab'"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=abricate
TOOL_NAME=ABRicate
TOOL_DOCS=https://github.com/tseemann/abricate
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                           # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/abricate:1.4.0--1c91d3be16669e36
container_path=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true

# Defaults - settings
# NOTE: The output file will have the same name as the input fasta, with the extension
#       switched to '.tab'

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/spades/assembly.fasta -o results/abricate --db vfdb"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input file"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --db                <str>   Database, e.g. 'card', 'vfdb' (see Abricate docs) [default: Abricate default => 'ncbi']"
    echo "  --minid             <int>   Minimum DNA % identity                  [default: Abricate default => 80]"
    echo "  --mincov             <int>  Minimum DNA % coverage                  [default: Abricate default => 80]"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "                                NOTE: If no default '--container_url' or '--container_dir' is listed below,"
    echo "                                you'll have to provide one of these in order to run the script with a container."
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or '--dl_container' is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --no_strict                 Don't use strict Bash settings ('set -euo pipefail') -- can be useful for troubleshooting"
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
infile=
outdir=
db=
minid= && id_opt=
mincov= && cov_opt=
opts=
version_only=false
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --db )              shift && db=$1 ;;
        --minid )           shift && minid=$1 ;;
        --mincov )          shift && mincov=$1 ;;
        --opts )            shift && opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --no_strict )       strict_bash=false ;;
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
[[ "$strict_bash" == true ]] && set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
outfile="$outdir"/"$(basename "${infile%.*}")".tab
[[ -n "$db" ]] && db_opt="--db $db"
[[ -n "$minid" ]] && id_opt="--minid $minid"
[[ -n "$mincov" ]] && cov_opt="--mincov $mincov"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input assembly FASTA file:                $infile"
echo "Output file:                              $outfile"
[[ -n "$db" ]] && echo "Database:                                 $db"
[[ -n "$minid" ]] && echo "Min. % identity:                          $minid"
[[ -n "$mincov" ]] && echo "Min. % coverage:                          $mincov"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --threads "$threads" \
    $db_opt \
    $id_opt \
    $cov_opt \
    $opts \
    "$infile" \
    > "$outfile"

#? To update a DB, run e.g. 'abricate-get_db --db vfdb --force'

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
