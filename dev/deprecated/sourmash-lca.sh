#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --mem=20G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=sourmash_classify
#SBATCH --output=slurm-sourmash_classify-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Taxonomically classify the sequence contained in a FASTA file using LCA classification with 'sourmash lca classify'"
SCRIPT_VERSION="2023-12-04"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="sourmash"
TOOL_NAME=Sourmash
TOOL_DOCS=https://sourmash.readthedocs.io
VERSION_COMMAND="sourmash --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/conda/sourmash_4.9.4
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
version_only=false                 # When true, just print tool & script version info and exit

# Constants - tool parameters etc
GTDB_DB=rs214
DB_FILENAME_PREFIX=gtdb-"$GTDB_DB"-k
K21_DB_URL=https://farm.cse.ucdavis.edu/~ctbrown/sourmash-db/gtdb-"$GTDB_DB"/"$DB_FILENAME_PREFIX"21.lca.json.gz
K31_DB_URL=https://farm.cse.ucdavis.edu/~ctbrown/sourmash-db/gtdb-"$GTDB_DB"/"$DB_FILENAME_PREFIX"31.lca.json.gz
K51_DB_URL=https://farm.cse.ucdavis.edu/~ctbrown/sourmash-db/gtdb-"$GTDB_DB"/"$DB_FILENAME_PREFIX"51.lca.json.gz

# Defaults - tool parameters etc
db_dir=/fs/ess/PAS0471/jelmer/refdata/sourmash
kmer=31

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
    echo "      sbatch $0 -i results/spades/my_asm.fna -o results/sourmash/db"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input file: nucleotide FASTA with .fa, .fasta, or .fna extension"
    echo "                              This would typically be a genome assembly and can contain multiple contigs/entries"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --db                <file>  Path to a .lca.json.gz sourmash database [default: download GTDB database]"
    echo "                              Curent version of the automatically downloaded GTDB database is: $GTDB_DB"
    echo "                              For DB info, see https://sourmash.readthedocs.io/en/latest/databases.html"
    echo "  --db_dir            <dir>   Directory to download GTDB database to   [default: $db_dir]"
    echo "  --kmer              <int>   Kmer size: 21, 31, or 51                 [default: $kmer]"
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
db=
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --db )              shift && db=$1 ;;
        --db_dir )          shift && db_dir=$1 ;;
        --kmer )            shift && kmer=$1 ;;
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
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# If needed, make dirs absolute because we have to move into the outdir
[[ ! $infile =~ ^/ ]] && infile="$PWD"/"$infile"
[[ ! $outdir =~ ^/ ]] && outdir="$PWD"/"$outdir"
[[ -n $db && ! $db =~ ^/ ]] && db="$PWD"/"$db"
[[ -n $db_dir && ! $db_dir =~ ^/ ]] && db_dir="$PWD"/"$db_dir"
sigfile=$(basename "$infile").sig # Sourmash signature file
file_id=$(basename "$infile" | sed -E 's/\.fn?as?t?a?//')
[[ -z "$db" ]] && db="$db_dir"/"$DB_FILENAME_PREFIX""$kmer".lca.json.gz

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input FASTA file:                         $infile"
echo "Output dir:                               $outdir"
echo "Kmer size:                                $kmer"
echo "Taxonomic database file:                  $db"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile" 
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Move to output dir
cd "$outdir" || exit

# Create a signature for the FASTA file
if [[ ! -f "$sigfile" ]]; then
    log_time "Create sourmash signature for query file... ($sigfile)"
    runstats $TOOL_BINARY sketch dna -p k="$kmer" "$infile"
else
    log_time "Sourmash signature file for query already exists ($sigfile)"
fi

# Download the taxonomic database - https://sourmash.readthedocs.io/en/latest/databases.html
if [[ -n "$db_dir" ]]; then
    if [[ ! -f "$db" ]]; then
        log_time "Downloading database for k=$kmer (See https://sourmash.readthedocs.io/en/latest/databases.html)"
        [[ "$kmer" = 21 ]] && curl --insecure -JL -o "$db" "$K21_DB_URL"
        [[ "$kmer" = 31 ]] && curl --insecure -JL -o "$db" "$K31_DB_URL"
        [[ "$kmer" = 51 ]] && curl --insecure -JL -o "$db" "$K51_DB_URL"
        [[ ! -f "$db" ]] && die "Downloaded DB file does not exist/have expected name $db"
    else
        log_time "Database file $db already exists"
    fi
fi

# Run Sourmash
log_time "Running sourmash classify..."
runstats $TOOL_BINARY lca classify \
    --db "$db" \
    --query "$sigfile" \
    $more_opts |
    tee > "$file_id".txt

# Wrap up
log_time "Showing the contents of the main output file $file_id.txt:"
cat "$file_id".txt
final_reporting "$LOG_DIR"
