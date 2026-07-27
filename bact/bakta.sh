#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bakta
#SBATCH --output=slurm-bakta-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Bakta to annotate a bacterial genome"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=bakta
TOOL_NAME=Bakta
TOOL_DOCS=https://github.com/oschwengers/bakta
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                           # Use a 'conda' env or a Singularity 'container'
conda_path=
container_path=docker://quay.io/biocontainers/bakta:1.8.2--pyhdfd78af_0
container_url=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true
version_only=false                 # When true, just print tool & script version info and exit

# Constants - tool parameters
DB_TYPE=full                    # Full rather than partial Bakta DB

# Defaults - tool parameters
db_dir=/fs/ess/PAS0471/jelmer/refdata/bakta
force_db_download=false

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
    echo "      sbatch $0 -i results/spades/sampleA.fna -o results/bakta --genus Salmonella --species enterica"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input assembly FASTA file"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  --genus             <str>   Genus name of focal organism"
    echo "  --species           <str>   Species name of focal organism"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
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
genus=
species=
min_contig_len= && contig_len_arg=
opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --genus )           shift && genus=$1 ;;
        --species )         shift && species=$1 ;;
        --db_dir )          shift && db_dir=$1 ;;
        --force_db_dl )     force_db_download=true ;;
        --min_contig_len )  min_contig_len=$1 ;;
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
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_args"
[[ -z "$genus" ]] && die "No genus name specified, do so with --genus" "$all_args"
[[ -z "$species" ]] && die "No species name specified, do so with --species" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
[[ -n "$min_contig_len" ]] && contig_len_arg="--min-contig-length $min_contig_len"
sample_id=$(basename "${infile%.*}")

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input FASTA file:                         $infile"
echo "Output dir:                               $outdir"
echo "Genus:                                    $genus"
echo "Species:                                  $species"
echo "Bakta DB dir:                             $db_dir"
echo "Force DB download:                        $force_db_download"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Download the Bakta DB
if [[ ! -d "$db_dir"/db || "$force_db_download" == true ]]; then
    log_time "Downloading the Bakta DB to $db_dir"
    bakta_db download --output "$db_dir" --type "$DB_TYPE"
else
    log_time "Found a Bakta DB in $db_dir/db, using that one..."
fi

# Run Bakta
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --output "$outdir" \
    --prefix "$sample_id" \
    --genus "$genus" \
    --species "$species" \
    --db "$db_dir"/db \
    $contig_len_arg \
    --threads "$threads" \
    --force \
    $opts \
    "$infile"

#? Other options
#--compliant           Force Genbank/ENA/DDJB compliance
#  --translation-table {11,4}
#                        Translation table: 11/4 (default = 11)
#  --gram {+,-,?}        Gram type for signal peptide predictions: +/-/? (default = ?)

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
