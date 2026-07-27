#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=5:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=sourmash_db
#SBATCH --output=slurm-sourmash-db-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Create a custom Sourmash database"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="sourmash"
TOOL_NAME=Sourmash
TOOL_DOCS="https://sourmash.readthedocs.io/en/latest/tutorial-basic.html#make-and-search-a-database-quickly"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/conda/sourmash_4.9.4
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true
version_only=false                 # When true, just print tool & script version info and exit

# Defaults - tool parameters
kmer_size=31
db_name=smash_db

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
    echo "      sbatch $0 -i data/ref_genomes -o results/sourmash_search_db"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <file>  Input dir with FASTA files (extensions .fa/.fasta/.fna)"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "                                The name of the database file will be: <outdir>/<db_name>.sbt.zip"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --db_name           <str>   Name (prefix) for the database files    [default: $db_name]"
    echo "                                The name of the database file will be: <outdir>/<db_name>.sbt.zip"
    echo "  --kmer_size         <int>   Kmer size (should be an odd integer)    [default: $kmer_size]"
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
indir=
outdir=
opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --kmer_size )       shift && kmer_size=$1 ;;
        --db_name )         shift && db_name=$1 ;;
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
[[ -z "$indir" ]] && die "No input dir specified, do so with -i/--indir" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# Define outputs based on script parameters
LOG_DIR="$PWD"/"$outdir"/logs && mkdir -p "$LOG_DIR"
sig_dir="$PWD"/"$outdir"/signatures && mkdir -p "$sig_dir"
indir=$(realpath "$indir") # Make dirs absolute because we have to move into the outdir

# Get input files
mapfile -t infiles < <(find "$indir" -iname '*fasta' -or -iname '*fa' -or -iname '*fna' -or -iname '*fna.gz')
[[ ${#infiles[@]} -eq 0 ]] && die "No .fa/.fasta/.fna/.fna.gz files found in indir $indir"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input dir:                                $indir"
echo "Output dir:                               $outdir"
echo "Database name:                            $db_name"
echo "Kmer size:                                $kmer_size"
echo "Number of input files:                    ${#infiles[@]}"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Move to output dir
log_time "Moving into the output dir $sig_dir..."
cd "$sig_dir" || exit

# Create signatures (sketches) for each input file
log_time "Creating genome sketches for each FASTA file..."
for fa in "${infiles[@]}"; do
    if [[ ! -f $(basename "$fa").sig ]]; then
        runstats $TOOL_BINARY \
            sketch dna -p k="$kmer_size" "$fa"
    fi
done

# Create the database
log_time "Creating the database with all genome sketches..."
cd ..
runstats $TOOL_BINARY \
    index -k"$kmer_size" "$db_name" $opts "$sig_dir"/*.sig

# Report
log_time "Listing files in the output dir:"
ls -lh
final_reporting "$LOG_DIR"
