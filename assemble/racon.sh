#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=40
#SBATCH --mem=170G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=racon
#SBATCH --output=slurm-racon-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Racon (Minimap then 1 or more rounds of Racon) to polish a genome
assembly either with short or long reads"
SCRIPT_VERSION="2026-05-19"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=racon
TOOL_NAME=Racon
TOOL_DOCS=https://github.com/lbcb-sci/racon
VERSION_COMMAND="$TOOL_BINARY --version; echo '# Version of Minimap:'; minimap2 --version"

# Defaults - generics
env_type=container              # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=TODO_CONTAINER_URL
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
minimap_preset="map-ont"
iterations=2

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
      sbatch $0 --assembly results/flye/assembly.fasta --reads data/fastq/my.fastq.gz -o results/racon

REQUIRED OPTIONS:
  --assembly          <file>  Input assembly: FASTA file (to be corrected)
  --reads             <file>  Input reads: FASTQ file (reads used for correction)
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --iterations        <int>   Number of Racon iterations (1 or 2)               [default: $iterations]
  --minimap_preset    <str>   Minimap preset                                    [default: $minimap_preset]
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
reads=
assembly_in=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --reads )               shift && reads=$1 ;;
        --assembly )            shift && assembly_in=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --minimap_preset )      shift && minimap_preset=$1 ;;
        --iterations )          shift && iterations=$1 ;;
        --more_opts )           shift && more_opts=$1 ;;
        --env_type )            shift && env_type=$1 ;;
        --conda_path )          shift && conda_path=$1 ;;
        --container_dir )       shift && container_dir=$1 ;;
        --container_url )       shift && container_url=$1 ;;
        --container_path )      shift && container_path=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version)         version_only=true ;;
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
load_env "$env_type" "$conda_path" "$container_dir" "$container_path" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$assembly_in" ]] && die "No input assembly FASTA file specified, do so with --assembly" "$all_opts"
[[ -z "$reads" ]] && die "No input FASTQ file specified, do so with --reads" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$assembly_in" ]] && die "Input assembly FASTA file $assembly_in does not exist"
[[ ! -f "$reads" ]] && die "Input reads FASTQ file $reads does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR" "$outdir"/minimap
assembly_ext=$(echo "$assembly_in" | sed -E 's/.*(\.fn?a?s?t?a$)/\1/')
assembly_id=$(basename "$assembly_in" "$assembly_ext")
assembly_out1="$outdir"/"$assembly_id"_racon1.fasta
[[ "$iterations" -eq 2 ]] && assembly_out2="$outdir"/"$assembly_id"_racon2.fasta
align_1="$outdir"/minimap/"$assembly_id"_iter1.sam
[[ "$iterations" -eq 2 ]] && align_2="$outdir"/minimap/"$assembly_id"_iter2.sam
[[ "$iterations" -gt 2 ]] && die "Number of Racon iterations cannot be greater than 2 (You asked for $iterations)"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input reads (FASTQ) file:                 $reads"
echo "Input assembly (FASTA) file:              $assembly_in"
echo "Output dir:                               $outdir"
echo "Nr of Racon iterations:                   $iterations"
echo "Minimap preset:                           $minimap_preset"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$reads" "$assembly_in"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               FUNCTIONS
# ==============================================================================
# Function to run Racon
Run_racon() {
    assembly_in=${1:-none}
    alignments=${2:-none}
    assembly_out=${3:-none}

    [[ $assembly_in == "none" ]] && die "No assembly for function Run_racon"
    [[ $alignments == "none" ]] && die "No alignments for function Run_racon"
    [[ $assembly_out == "none" ]] && die "No outfile for function Run_racon"

    runstats $TOOL_BINARY \
        "$reads" \
        "$alignments" \
        "$assembly_in" \
        -t "$threads" \
        $more_opts \
        > "$assembly_out"
}

# Function to run Minimap
Run_minimap() {
    assembly=${1:-none}
    align_out=${2:-none}

    [[ $assembly == "none" ]] && die "No assembly for function Run_minimap"
    [[ $align_out == "none" ]] && die "No outfile for function Run_minimap"

    runstats minimap2 \
        -x "$minimap_preset" \
        -t "$threads" \
        -a \
        "$assembly" \
        "$reads" \
        > "$align_out"
}

# ==============================================================================
#                               RUN
# ==============================================================================
# Minimap iteration 1
if [[ ! -s "$align_1" ]]; then
    log_time "Now running the first iteration of Minimap..."
    Run_minimap "$assembly_in" "$align_1"
else
    log_time "Minimap SAM from iteration 1 exists, skipping step..."
    ls -lh "$align_1"
fi

# Racon iteration 1
if [[ ! -s "$assembly_out1" ]]; then
    echo -e "\n====================================================================="
    log_time "Now running the first iteration of Racon..."
    Run_racon "$assembly_in" "$align_1" "$assembly_out1"
else
    log_time "Assembly from Racon iteration 1 exists, skipping step..."
    ls -lh "$assembly_out1"
fi

if [[ "$iterations" -eq 2 ]]; then
    # Minimap iteration 2
    if [[ ! -s "$align_2" ]]; then
        echo -e "\n====================================================================="
        log_time "Now running the second iteration of Minimap..."
        Run_minimap "$assembly_out1" "$align_2"
    else
        log_time "Minimap SAM from iteration 2 exists, skipping step..."
        ls -lh "$align_2"
    fi

    # Racon iteration 2
    if [[ ! -s "$assembly_out2" ]]; then
        echo -e "\n====================================================================="
        log_time "Now running the second iteration of Racon..."
        Run_racon "$assembly_out1" "$align_2" "$assembly_out2"
    else
        log_time "Assembly from Racon iteration 2 exists, skipping step..."
        ls -lh "$assembly_out2"
    fi
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
