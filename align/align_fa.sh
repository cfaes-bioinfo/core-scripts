#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=align_fa
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Align nucleotide or amino acid sequences in a multi-FASTA file with MAFFT (default) or MUSCLE"
SCRIPT_VERSION="2026-09-02"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_NAME="MAFFT/MUSCLE"    # Set to the specific aligner after arg parsing
TOOL_BINARY=                # Set to the specific aligner after arg parsing
VERSION_COMMAND=            # Set to the specific aligner after arg parsing
TOOL_DOCS="https://mafft.cbrc.jp/alignment/software/ and https://drive5.com/muscle5/"

# Defaults - generic
env_type=container
container_url=oras://community.wave.seqera.io/library/mafft_muscle:6bc02d6c63260b9a # MAFFT 7.525 + MUSCLE 5.3
container_dir="$HOME/containers"
container_path=
conda_path=/fs/ess/PAS0471/jelmer/conda/mafft   # Also contains MUSCLE

# Defaults - tool parameters
aligner=mafft
fix_header=true

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
  - Basic usage (MAFFT):
      sbatch $0 -i data/my.fasta -o results/align/aligned.fasta
  - Use MUSCLE instead:
      sbatch $0 -i data/my.fasta -o results/align/aligned.fasta --aligner muscle
  - Pass extra options to the aligner:
      sbatch $0 -i data/my.fasta -o results/align/aligned.fasta --more_opts \"--maxiterate 1000\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input multi-FASTA file with sequences to be aligned
                              FASTA can contain either nucleotide or amino acid (protein) sequences
  -o/--outfile        <file>  Output FASTA file with the alignment
                              (dir will be created if needed)

OTHER KEY OPTIONS:
  --aligner           <str>   Aligner: 'mafft' or 'muscle'                      [default: $aligner]
  --no_header_fix             Don't fix output FASTA headers                    [default: fix headers]
                              By default, the script removes aligner-added
                              header text after the first space, and the '_R_'
                              prefix that MAFFT adds to reverse-complemented seqs
  --more_opts         <str>   Quoted string with one or more additional options
                              for the aligner

OUTPUT:
  Alongside the alignment, '<outfile-dir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of the aligner
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:
  --env_type          <str>   Software environment: 'conda', 'container'        [default: $env_type]
                              (Singularity/Apptainer), or 'none' (tool must
                              already be available in your PATH)
  --container_url     <str>   URL/URI to download a container from              [default: ${container_url:-none}]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_path    <file>  Local container image file ('.sif') to use        [default: ${container_path:-none}]
  --conda_path        <dir>   Full path to a Conda environment to use           [default: ${conda_path:-none}]
  -h/--help                   Print this help message
  -v/--version                Print script and aligner versions

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
if [[ -z "${SLURM_JOB_ID:-}" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script "$IS_SLURM"

# Report clearly if this script exits with a non-zero status
trap report_on_exit EXIT

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false  # When true, just print tool & script version info and exit
infile=
outfile=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outfile )    check_val "$1" "${2:-}"; shift; outfile=$1 ;;
        --aligner )         check_val "$1" "${2:-}"; shift; aligner=$1 ;;
        --no_header_fix )   fix_header=false ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )      check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )  check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )    version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Constants and vars based on the aligner choice
# NOTE: this has to happen before 'load_env', which prepends the container
#       prefix to TOOL_BINARY and VERSION_COMMAND
if [[ "$aligner" == "mafft" ]]; then
    TOOL_BINARY=mafft
    TOOL_NAME=MAFFT
    VERSION_COMMAND="mafft --version 2>&1"  # MAFFT prints its version to stderr
elif [[ "$aligner" == "muscle" ]]; then
    TOOL_BINARY=muscle
    TOOL_NAME=MUSCLE
    VERSION_COMMAND="muscle -version"
else
    die "Aligner ('--aligner') should be 'mafft' or 'muscle' but is '$aligner'" "$all_opts"
fi

# Check software env
[[ -z "$TOOL_BINARY" ]] && die "TOOL_BINARY has not been set in this script"
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

# Print version info and exit, if requested (this needs the software env loaded)
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outfile" ]] && die "No output file specified, do so with -o/--outfile" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
outdir=$(dirname "$outfile")
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"
n_in=$(grep -c "^>" "$infile" || true)

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "Output file:                              $outfile"
echo "Output dir:                               $outdir"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
echo "Aligner:                                  $TOOL_NAME"
echo "Fix the output FASTA headers?             $fix_header"
echo "Number of sequences in the input file:    $n_in"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# Run the alignment
log_time "Running $TOOL_NAME..."
if [[ "$aligner" == "mafft" ]]; then
    runstats $TOOL_BINARY \
        --reorder \
        --auto \
        --adjustdirection \
        --leavegappyregion \
        --thread "$threads" \
        $more_opts \
        "$infile" > "$outfile"
else
    runstats $TOOL_BINARY \
        -align "$infile" \
        -output "$outfile" \
        -threads "$threads" \
        $more_opts
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
# Remove aligner-added extra info after a space from FASTA header lines,
# and remove the "_R_" prefix that MAFFT adds to reverse-complemented seqs
if [[ "$fix_header" == true ]]; then
    log_time "Fixing FASTA headers..."
    sed -i -E -e 's/(^>[^ ]+) .*/\1/' -e 's/^>_R_/>/' "$outfile"
fi

log_time "Number of sequences in the output file:   $(grep -c "^>" "$outfile" || true)"
log_time "Listing the output file:"
ls -lh "$outfile"
final_reporting
