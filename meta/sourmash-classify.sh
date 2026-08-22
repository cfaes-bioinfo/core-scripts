#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=5
#SBATCH --mem=20G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=sourmash_classify
#SBATCH --output=slurm-sourmash_classify-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Taxonomically classify the sequence contained in a FASTA file using 'sourmash tax'"
SCRIPT_VERSION="2025-09-28"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=sourmash
TOOL_NAME=Sourmash
TOOL_DOCS=https://sourmash.readthedocs.io/
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                  # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/conda/sourmash_4.9.4
container_url=
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters etc
GTDB_DB=rs220
DB_FILENAME_PREFIX=gtdb-"$GTDB_DB"-k
URL_PREFIX="https://farm.cse.ucdavis.edu/~ctbrown/sourmash-db.new/gtdb"
K21_DB_URL="$URL_PREFIX"-"$GTDB_DB"/"$DB_FILENAME_PREFIX"21.dna.zip
K31_DB_URL="$URL_PREFIX"-"$GTDB_DB"/"$DB_FILENAME_PREFIX"31.dna.zip
K51_DB_URL="$URL_PREFIX"-"$GTDB_DB"/"$DB_FILENAME_PREFIX"51.dna.zip
TAX_CSV_FILENAME=gtdb-"$GTDB_DB".lineages.csv
TAX_CSV_URL="$URL_PREFIX"-"$GTDB_DB"/"$TAX_CSV_FILENAME"

# Defaults - tool parameters
kmer=31
threshold_bp=10000
db_dir=/fs/ess/PAS0471/refdata/sourmash

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "
                        $0
    v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL
            =================================================

DESCRIPTION:
$DESCRIPTION
    
USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i results/spades/my_asm.fna -o results/sourmash
    
REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTA file
                              This is typically be a (meta)genome assembly and
                              can contain multiple contigs/entries.
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --kmer              <int>   Kmer size: 21, 31, or 51                          [default: $kmer]
  --threshold_bp      <int>   Min. contig size (smaller contigs are excluded)   [default: $threshold_bp]
  --db                <file>  Path to a .zip sourmash database                  [default: download GTDB database]
                              Current version of the automatically downloaded
                              GTDB database is: $GTDB_DB.
                              For DB info, see:
                              https://sourmash.readthedocs.io/en/latest/databases.html
  --db_dir            <dir>   Directory to download GTDB database to            [default: $db_dir]
    
UTILITY OPTIONS:
  --env_type          <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                              ('container') or a Conda environment ('conda') 
  --container_url     <str>   URL to download a container from                  [default (if any): $container_url]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_path    <file>  Local container image file ('.sif') to use        [default (if any): $container_path]
  --conda_path        <dir>   Full path to a Conda environment to use           [default (if any): $conda_path]
  -h/--help                   Print this help message
  -v/--version                Print script and $TOOL_NAME versions
    
TOOL DOCUMENTATION:
  $TOOL_DOCS
"
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
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -f "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -f "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script_name"
        fi
        source "$function_script_name"
    fi
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false  # When true, just print tool & script version info and exit
infile=
outdir=
db=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --kmer )            shift && kmer=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --conda_path )      shift && conda_path=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
        --container_path )  shift && container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
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
load_env "$env_type" "$conda_path" "$container_dir" "$container_path" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define output files
sigfile="$outdir"/$(basename "$infile").sig # Sourmash signature file
file_id=$(basename "$infile" | sed -E 's/\.fn?as?t?a?//')
gather_csv="$outdir"/"$file_id"_gather.csv
[[ -z "$db" ]] && db="$db_dir"/"$DB_FILENAME_PREFIX""$kmer".zip
tax_csv="$db_dir"/"$TAX_CSV_FILENAME"

# Make output dirs
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR" "$db_dir"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "File ID:                                  $file_id"
echo "Output dir:                               $outdir"
echo "Kmer size:                                $kmer"
echo "Taxonomic database file:                  $db"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Download the taxonomic database
if [[ -n "$db_dir" ]]; then
    if [[ ! -f "$db" ]]; then
        log_time "Downloading database for k=$kmer (see https://sourmash.readthedocs.io/en/latest/databases.html)"
        [[ "$kmer" = 21 ]] && runstats curl --insecure -JLsS -o "$db" "$K21_DB_URL"
        [[ "$kmer" = 31 ]] && runstats curl --insecure -JLsS -o "$db" "$K31_DB_URL"
        [[ "$kmer" = 51 ]] && runstats curl --insecure -JLsS -o "$db" "$K51_DB_URL"
        [[ ! -f "$db" ]] && die "Downloaded DB file does not exist/have expected name $db"
    else
        log_time "Database file $db already exists, not downloading"
    fi
    if [[ ! -f "$tax_csv" ]]; then
        log_time "Downloading taxonomy CSV file to $tax_csv..."
        runstats curl --insecure -JLsS -o "$tax_csv" "$TAX_CSV_URL" 
    else
        log_time "Taxonomy CSV file $tax_csv already exists, not downloading"
    fi
fi

# Create a signature for the FASTA file
if [[ ! -f "$sigfile" ]]; then
    log_time "Create sourmash signature for query file... ($sigfile)"
    runstats $TOOL_BINARY sketch dna \
        -p abund,k="$kmer" \
        --output "$sigfile" \
        "$infile"
    #! Can use --singleton to generate signature for each sequence record separately
else
    log_time "Sourmash signature file for query already exists ($sigfile)"
fi

# Run sourmash gather
log_time "Running sourmash gather..."
runstats $TOOL_BINARY gather \
    --output "$gather_csv" \
    --threshold-bp "$threshold_bp" \
    "$sigfile" \
    "$db"

#? The command line option `--threshold-bp` sets the threshold below
#? which matches are no longer reported; by default, this is set to
#? 50kb. see the Appendix in Classifying Signatures [1] for details.

# Run sourmash tax
log_time "Running sourmash tax..."
runstats $TOOL_BINARY tax metagenome \
    --gather-csv "$gather_csv" \
    --taxonomy-csv "$tax_csv" \
    --use-abundances \
    --rank species \
    --output-format human \
    --output-format csv_summary \
    --output-format krona \
    --output-format lineage_summary \
    --output-format kreport \
    --output-dir "$outdir" \
    --output-base "$file_id"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
