#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=12
#SBATCH --mem=160G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=emu
#SBATCH --output=slurm-emu-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Emu to estimate taxon abundances directly from 16S ONT reads"
SCRIPT_VERSION="2025-01-19"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="emu abundance"
TOOL_NAME=Emu
TOOL_DOCS=https://github.com/treangenlab/emu
VERSION_COMMAND="emu --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/emu:3.5.5--d530f68835d7c040
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
data_type=map-ont                   # Same default as Emu, other options are 'map-pb' (for PacBio) and 'sr' (for short reads/Illumina)
max_aln=25                          # Emu default is 25 but leads to v high RAM usage

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
      sbatch $0 -i my.fastq.gz -o results/emu
    
REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTQ file
  -o/--outdir         <dir>   Output dir (will be created if needed)
  --db                <dir>   Path to Emu database directory
                              To download prebuilt Emu databases, see
                              <https://github.com/treangenlab/emu?tab=readme-ov-file#1-download-database>
    
OTHER KEY OPTIONS:
  --data_type         <str>   Sequence type, one of: 'map-ont' (ONT),
                              'map-pb' (PacBio), 'sr' (short reads/Illumina)   [default: $data_type]
  --max_aln           <int>   Max nr. of alignments for each read in minimap2  [default: $max_aln]
                              Lower numbers will reduce RAM usage
  --more_opts         <str>   Quoted string with one or more additional
                              options for $TOOL_NAME
    
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
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false  # When true, just print tool & script version info and exit
infile=
outdir=
db=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --data_type )       shift && data_type=$1 ;;
        --db )              shift && db=$1 ;;
        --max_aln )         shift && max_aln=$1 ;;
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
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$db" ]] && die "No database directory specified, do so with --db" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -d "$db" ]] && die "Database directory $db does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "Output dir:                               $outdir"
echo "Max. nr. of alignments per read:          $max_aln"
echo "Database dir:                             $db"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
log_time "Listing the files in the database dir:"
ls -lh "$db"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --type "$data_type" \
    --output-dir "$outdir" \
    --db "$db" \
    --keep-read-assignments \
    --keep-counts \
    --output-unclassified \
    --N "$max_aln" \
    --threads "$threads" \
    $more_opts \
    "$infile"

# TODO - Include min-abundance parameter?
#? A second influential parameter within Emu is the minimum abundance threshold (–minabundance).
#? Due to the nature of the EM algorithm, the estimated community composition often comprises a
#? long tail of species with extremely low abundances. A default minimum abundance threshold parameter
#? of 0.0001 has been set, such that relative abundance estimates below this value are deemed not present
#? in the sample. If the input sequencing reads contains more than 100,000 reads,
#? an additional composition estimate will be returned with a lower (more inclusive) minimum abundance
#? threshold that is the equivalent of 10 reads. The user can then decide which profile to use based 
#? on the needs of the study. In the situation where the input sample has under 1000 reads,
#? only one composition estimate is returned with the minimum abundance threshold is set to the
#? equivalent of 1 read.

#? Other emu commands:
#? emu build-db            Build a custom Emu database
#? emu collapse-taxonomy   Summarize to higher taxonomic levels
#? emu combine-outputs     Combine multiple Emu output files into one

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
#log_time "Listing files in the output dir:"
#ls -lhd "$(realpath "$outdir")"/*
#This failed when looping over multiple input files - need sample-specific listing, turning off for now
final_reporting "$LOG_DIR"
