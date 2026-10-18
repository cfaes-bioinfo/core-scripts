#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=sprot-download
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Download the current Swiss-Prot protein FASTA (~89 MB gzipped) for the functional annotation searches"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=wget
TOOL_NAME="wget (Swiss-Prot download)"
TOOL_DOCS=https://www.uniprot.org/help/downloads
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
# NOTE: 'none' - this only needs wget, which is always available
env_type=none
container_url=
conda_path=
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters
RELNOTES_URL=https://ftp.uniprot.org/pub/databases/uniprot/current_release/relnotes.txt

# Defaults - tool parameters
# The whole of Swiss-Prot, not a taxonomic subset: reciprocal best hits decide
# what is transferred, and a non-vertebrate curated entry can legitimately be
# the RBH partner of a deeply conserved gene. The source organism travels with
# every hit ('OS=' in the FASTA header), so anything odd stays visible.
sprot_url=https://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.fasta.gz

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

  The download is resumable: rerunning with the same --outdir picks a partial
  file up with 'wget --continue' rather than starting over.

  The UniProt release number is NOT in the FASTA file, and 'current_release'
  moves every eight weeks. So the release notes are fetched alongside it and the
  release string is written to '<outdir>/uniprot-release.txt' - that is the
  version to cite in the methods.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -o results/func-annot/refs/sprot

REQUIRED OPTIONS:
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --sprot_url         <str>   URL of the Swiss-Prot FASTA to download
                              [default: current_release]

OUTPUT:
  <outdir>/uniprot_sprot.fasta.gz  - Swiss-Prot, gzipped ('diamond makedb'
                                     reads it compressed, so it is left as-is)
  <outdir>/uniprot-release.txt     - The UniProt release these sequences are from

  Alongside those, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
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
  -v/--version                Print script and $TOOL_NAME versions

TOOL DOCUMENTATION:
  $TOOL_DOCS
"
}

# Function to source the script with Bash functions
source_function_script() {
    local is_slurm=${1:-false}

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
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -s "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -s "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            # Download to a temp file, then move into place, so that concurrent
            # jobs can never source a half-written file
            tmp_script=$(mktemp "$function_script_name".XXXXXX)
            if ! wget -q "$FUNCTION_SCRIPT_URL" -O "$tmp_script"; then
                rm -f "$tmp_script"
                echo "ERROR: Failed to download $FUNCTION_SCRIPT_URL" >&2
                exit 1
            fi
            mv -f "$tmp_script" "$function_script_name"
        fi
        source "$function_script_name"
    fi

    # Make sure the functions were really loaded
    if ! declare -F log_time check_val >/dev/null; then
        echo "ERROR: Sourced $function_script_name but its functions are missing" >&2
        echo "       (an outdated copy may be cached - try deleting it)" >&2
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
outdir=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o | --outdir )      check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --sprot_url )        check_val "$1" "${2:-}"; shift; sprot_url=$1 ;;
        --env_type )         check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )       check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )    check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )    check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )   check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )        script_help; exit 0 ;;
        -v | --version)      version_only=true ;;
        * )                  die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Print version info and exit, if requested
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"

# Define outputs based on script parameters
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
sprot_file="$outdir"/"$(basename "$sprot_url")"
release_file="$outdir"/uniprot-release.txt

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Output dir:                               $outdir"
echo "Swiss-Prot URL:                           $sprot_url"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

log_time "Recording the UniProt release..."
# The release line is the first non-empty line of the release notes
# NOTE: awk must drain the whole stream (no early 'exit') - exiting early would
# close the pipe while wget is still writing, and under 'pipefail' wget's
# resulting broken-pipe I/O error (exit 3) would kill this script
wget -q -O - "$RELNOTES_URL" | awk '!done && NF {print; done=1}' > "$release_file"
cat "$release_file"

log_time "Downloading Swiss-Prot..."
# '--continue' resumes a partial file from an interrupted run
runstats wget --continue --show-progress -O "$sprot_file" "$sprot_url"

log_time "Counting the downloaded sequences..."
# 'zgrep -c' would exit 1 on no match, which would kill the script under 'set -e'
n_seqs=$(zcat "$sprot_file" | grep -c '^>' || true)
echo "Number of Swiss-Prot sequences:           $n_seqs"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
log_time "Cite this release in the methods: $(cat "$release_file")"
final_reporting   # Note: reads the LOG_DIR global, takes no args
