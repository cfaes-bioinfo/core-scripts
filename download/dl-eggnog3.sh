#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=8G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=eggnog-download
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Download the eggNOG 7 database (~46 GB) that eggNOG-mapper v3 annotates from"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=download_eggnog_data.py
TOOL_NAME="eggNOG-mapper database download"
TOOL_DOCS=https://github.com/eggnogdb/eggnog-mapper/wiki
VERSION_COMMAND="emapper.py --version"

# Defaults - generic
env_type=conda
conda_path=/fs/ess/PAS0471/conda/eggnog-mapper_3.0.0b6
container_url=
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters
# The two big artifacts, checked for at the end - a truncated download of either
# one is the failure mode that matters, because emapper would then either crash
# deep into a run or annotate from a partial database
EXPECTED_FILES=(eggnog.db eggnog_proteins.dmnd eggnog.taxa.db)
MIN_GB=20                       # Both big files are >20 GB as of 2026-08

# Defaults - tool parameters
# The data server (data.cgmlab.org/eggnog-mapper/emapper-3.0/data) returns 404
# for manifest.json as of 2026-08-29, so there are no checksums to verify
# against and the downloader's verification step cannot run. Turn it back on
# with --verify once the manifest appears.
no_verify=true

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

  Pulls eggnog.db (~22.9 GB), eggnog_proteins.dmnd (~23.2 GB) and the taxonomy
  DB. Put this on scratch, not in the project dir.

  WHY eggNOG 7 AND NOT THE COPY ALREADY ON THIS FILESYSTEM:
  /fs/ess/PAS0471/refdata/eggnog holds emapperdb-5.0.2 - eggNOG 5.0, built in
  March 2021. That is not an out-of-date download: 5.0.2 is the newest database
  the eggNOG-mapper 2.1.x line can read, and there is no emapperdb-6.0 on the
  eggNOG 5 server at all. Current orthology data exists only behind
  eggNOG-mapper v3, which is still a pre-release.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -o /fs/ess/PAS0471/refdata/eggnog/eggnog7

REQUIRED OPTIONS:
  -o/--outdir         <dir>   Dir to download the database into (will be created)

OTHER KEY OPTIONS:
  --verify                    Verify downloads against the server's manifest.json
                              [default: skipped - the manifest 404s, see above]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME (e.g. '-P' to also fetch the Pfam DB)

OUTPUT:
  <outdir>/eggnog.db               - annotation database
  <outdir>/eggnog_proteins.dmnd    - DIAMOND database of eggNOG proteins
  <outdir>/eggnog.taxa.db          - taxonomy database (+ its .traverse.pkl)

  Alongside those, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment
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
more_opts=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o | --outdir )      check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --verify )           no_verify=false ;;
        --more_opts )        check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
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
# Check software env
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"

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
# The downloader requires --data_dir to exist already
mkdir -p "$outdir"

# Build the option string
verify_opt=
[[ "$no_verify" == true ]] && verify_opt="--no-verify"

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
echo "Output (database) dir:                    $outdir"
echo "Verify against manifest.json:             $([[ "$no_verify" == true ]] && echo no || echo yes)"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME: $more_opts"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

# download_eggnog_data.py (v3.0.0b6) unconditionally resolves and sets the
# DEFAULT_BACKEND data path (<env>/lib/pythonX.Y/site-packages/data) before it
# ever looks at --data_dir, and that path requires the directory to already
# exist. The pip package ships no such dir, so the script crashes on every
# call - regardless of --data_dir - unless it's pre-created. --data_dir
# overwrites this path right after, so the placeholder dir is never used.
site_pkg_data_dir=$(python3 -c "import eggnogmapper, os; print(os.path.join(os.path.dirname(os.path.dirname(eggnogmapper.__file__)), 'data'))")
mkdir -p "$site_pkg_data_dir"

log_time "Downloading the eggNOG database..."
# '-y' answers the interactive prompts; the downloader skips artifacts that are
# already complete, so a rerun after an interrupted job resumes rather than restarts
eval runstats "$TOOL_BINARY" \
    -y \
    --data_dir "$outdir" \
    $verify_opt \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Checking that the expected files arrived, and are not truncated..."
# Without a manifest there are no checksums, so size is the only guard against a
# partial download that would otherwise surface as a crash mid-annotation
missing=0
for f in "${EXPECTED_FILES[@]}"; do
    if [[ ! -s "$outdir"/"$f" ]]; then
        log_time "WARNING: expected file $f is missing or empty"
        missing=$(( missing + 1 ))
    else
        size_gb=$(du -B1 "$outdir"/"$f" | awk '{printf "%.1f", $1/1024/1024/1024}')
        echo "  $f: $size_gb GB"
        if [[ "$f" != eggnog.taxa.db ]] &&
           awk -v s="$size_gb" -v m="$MIN_GB" 'BEGIN {exit !(s < m)}'; then
            log_time "WARNING: $f is only $size_gb GB, expected > $MIN_GB GB - rerun this script to resume"
            missing=$(( missing + 1 ))
        fi
    fi
done
[[ "$missing" -gt 0 ]] && die "$missing expected database file(s) missing or truncated"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
log_time "Point annot/eggnogmap3.sh at this dir with '--db_dir $outdir'"
final_reporting   # Note: reads the LOG_DIR global, takes no args
