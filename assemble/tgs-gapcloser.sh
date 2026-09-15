#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=120:00:00
#SBATCH --cpus-per-task=20
#SBATCH --mem=1500G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=tgs_gapcloser
#SBATCH --output=slurm-tgs_gapcloser-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run TGS-GapCloser to close gaps in a genome assembly using long reads"
SCRIPT_VERSION="2026-05-21"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=tgsgapcloser
TOOL_NAME=TGS-GapCloser
TOOL_DOCS=https://github.com/BGI-Qingdao/TGS-GapCloser
VERSION_COMMAND="$TOOL_BINARY 2>&1 | sed -n 2p"
RACON_BINARY=/opt/conda/bin/racon

# Defaults - generics
env_type=container
conda_path=
container_dir="$HOME/containers"
# NOTE: Container must also contain Racon
container_url=oras://community.wave.seqera.io/library/racon_tgsgapcloser:f5cff7113752c53d
container_path=

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
  - Basic usage:
      sbatch $0 --assembly results/assembly.fasta --reads reads.fasta -o results/tgs/gapclosed.fasta

REQUIRED OPTIONS:
  --assembly        <file>  Input assembly FASTA file
  --reads           <file>  Input long-read FASTA file (Note: FASTA, not FASTQ)
  -o/--outfile      <file>  Output assembly FASTA file (dir will be created if needed)

OTHER KEY OPTIONS:
  --more_opts       <str>   Quoted string with one or more additional options
                            for $TOOL_NAME

UTILITY OPTIONS:
  --env_type        <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                            ('container') or a Conda environment ('conda')
  --container_url   <str>   URL to download a container from                  [default (if any): $container_url]
  --container_dir   <str>   Dir to download a container to                    [default: $container_dir]
  --container_path  <file>  Local container image file ('.sif') to use        [default (if any): $container_path]
  --conda_path      <dir>   Full path to a Conda environment to use           [default (if any): $conda_path]
  -h/--help                 Print this help message
  -v/--version              Print script and $TOOL_NAME versions

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
version_only=false
assembly=
reads=
outfile=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --assembly )        shift && assembly=$1 ;;
        --reads )           shift && reads=$1 ;;
        -o | --outfile )    shift && outfile=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --conda_path )      shift && conda_path=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
        --container_path )  shift && container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )    version_only=true ;;
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
[[ -z "$assembly" ]] && die "No assembly specified, do so with --assembly" "$all_opts"
[[ -z "$reads" ]] && die "No reads file specified, do so with --reads" "$all_opts"
[[ -z "$outfile" ]] && die "No output file specified, do so with -o/--outfile" "$all_opts"
[[ ! -f "$assembly" ]] && die "Input assembly file $assembly does not exist"
[[ ! -f "$reads" ]] && die "Input reads file $reads does not exist"

# Define outputs based on script parameters
outdir=$(dirname "$outfile")
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

# Make paths absolute (tgs-gapcloser creates files in working dir)
[[ ! "$assembly" =~ ^/ ]] && assembly="$PWD"/"$assembly"
[[ ! "$reads" =~ ^/ ]] && reads="$PWD"/"$reads"
[[ ! "$outfile" =~ ^/ ]] && outfile="$PWD"/"$outfile"

# Determine output prefix
file_ext=$(basename "$outfile" | sed -E 's/.*(.fasta|.fa|.fna)$/\1/')
out_prefix=$(basename "$outfile" "$file_ext")

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input assembly FASTA:                     $assembly"
echo "Input long reads FASTA:                   $reads"
echo "Output assembly file:                     $outfile"
echo "Racon executable for $TOOL_NAME:          $RACON_BINARY"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$assembly" "$reads"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Move into the outdir since tgs-gapcloser creates files in the working dir
cd "$outdir" || exit 1

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --scaff "$assembly" \
    --reads "$reads" \
    --output "$out_prefix" \
    --racon "$RACON_BINARY" \
    --thread "$threads" \
    $more_opts

log_time "Copying the output file:"
cp -v "$out_prefix".scaff_seqs "$outfile"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing the output file:"
ls -lh "$outfile"
final_reporting "$LOG_DIR"
