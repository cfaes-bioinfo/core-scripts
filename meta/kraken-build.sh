#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=30:00:00
#SBATCH --mem=100G
#SBATCH --cpus-per-task=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=kraken_build
#SBATCH --output=slurm-kraken_build-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Build a custom Kraken database
  Note: Standard Kraken databases can be downloaded from https://benlangmead.github.io/aws-indexes"
SCRIPT_VERSION="2025-09-28"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=kraken2-build
TOOL_NAME=Kraken-build
TOOL_DOCS=https://github.com/DerrickWood/kraken2/blob/master/docs/MANUAL.markdown
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                  # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/conda/kraken_2.1.6
container_url=
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
libs=false

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
      sbatch $0 -o refdata/kraken/my_db --genome_dir refdata/kraken/my_db/genomes
      sbatch $0 -o refdata/kraken/my_db --libs 'archaea,bacteria,viral'
    
REQUIRED OPTIONS:
    -o/--db_dir       <dir>   Dir for the Kraken DB
    
OTHER KEY OPTIONS:
    --libs            <str>   Comma-separated list of reference libraries       [default:none]
                              to include in the DB (see below for options)
                              Options: 'archaea', 'bacteria', 'viral', 'plasmid',
                              'human', 'fungi', 'plant', 'protozoa',
                              'UniVec', 'UniVec_Core', 'nr', 'nt'
                              See https://github.com/DerrickWood/kraken2/blob/master/docs/MANUAL.markdown#custom-databases
  --genome_fa         <file>  Custom genome FASTA file to be added to the db
                              (use this to add a single genome/file)
  --genome_dir        <dir>   Dir with custom genome FASTA files
                              (use this to add multiple genomes/files)
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME
    
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
db_dir=
genome_fa=
genome_dir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -o | --db_dir )     shift && db_dir=$1 ;;
        --genome_fa )       shift && genome_fa=$1 ;;
        --genome_dir )      shift && genome_dir=$1 ;;
        --libs )            shift && libs=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
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
[[ -z "$db_dir" ]] && die "No db dir specified, do so with -o/--db" "$all_opts"

# Define outputs based on script parameters
LOG_DIR="$db_dir"/logs
mkdir -p "$LOG_DIR" "$db_dir"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Output database dir:                      $db_dir"
[[ -n $genome_fa ]] && echo "Genome to be added to DB:                 $genome_fa"
[[ -n $genome_dir ]] && echo "Dir with genomes to be added to DB:       $genome_dir"
[[ $libs != false ]] && echo "Libraries to download:                    $libs"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
[[ -n $genome_fa ]] && echo -e "\nListing the input genome(s):"
[[ -n $genome_fa ]] && ls -lh "$genome_fa"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Download NCBI taxonomy
if [[ ! -d "$db_dir"/taxonomy ]]; then
    log_time "Downloading taxonomy..."
    runstats $TOOL_BINARY --download-taxonomy --db "$db_dir" --threads "$threads"
else
    log_time "Taxonomy dir already exists, not downloading again"
fi

# Download taxon-specific 'libraries'
if [[ "$libs" != "false" ]]; then
    
    IFS="," read -ra lib_array <<< "$libs"
    
    for lib in "${lib_array[@]}"; do
        if [[ ! -d "$db_dir"/library/"$lib" ]]; then
            log_time "Downloading library: $lib..."
            $TOOL_BINARY --download-library "$lib" --db "$db_dir" --threads "$threads"
        else
            log_time "Library dir for $lib already exists, not downloading again"
        fi
    done
fi

# Add custom genoms
if [[ -n "$genome_fa" ]]; then
    # If there is a single genome to be added
    log_time "Adding custom genome $genome_fa to Kraken library..."
    $TOOL_BINARY --add-to-library "$genome_fa" --db "$db_dir" --threads "$threads"
elif [[ -n "$genome_dir" ]]; then
    # If all genomes in a dir should be added
    shopt -s nullglob
    for genome_fa in "$genome_dir"/*.{fa,fasta,fna}; do
        log_time "Adding custom genome $genome_fa to Kraken library..."
        $TOOL_BINARY --add-to-library "$genome_fa" --db "$db_dir" --threads "$threads"
    done
else
    log_time "Not adding any custom genomes"
fi

# Build the database
log_time "Building the database..."
runstats $TOOL_BINARY \
    --build \
    --db "$db_dir" \
    --threads "$threads" \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$db_dir")"/*
final_reporting "$LOG_DIR"
