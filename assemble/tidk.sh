#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=tidk
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Count telomeric repeats in windows along each contig with tidk"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="tidk search"
TOOL_NAME=tidk
TOOL_DOCS=https://github.com/tolkit/telomeric-identifier
VERSION_COMMAND="tidk --version"

# Defaults - generic
env_type=container                  # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/tidk:0.2.65--ef5a181df8a7c7b3
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
motif=AACCCT                        # --string: canonical vertebrate telomere unit (= TTAGGG / CCCTAA)
window=10000                        # --window: window size for the repeat counts

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

  This gives the repeat counts per window, which is what tidk produces and all
  it produces: none of its subcommands ('build', 'find', 'explore', 'search',
  'plot') emits a per-contig telomere call. The counts describe where telomeric
  repeat sits along a contig, interstitial tracts included - those are common in
  many vertebrate genomes.

  For a per-contig call, use the VGP telomere pipeline (find_telomere; the VGP
  criterion) or 'assemble/seqtk-telo.sh' (terminus-anchored, stricter). Both
  apply a published criterion, which thresholding tidk's windows does not.

  Note that tidk's last window on a contig is a PARTIAL window (here 214 bp to
  9,938 bp), so its count is not comparable with the others.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i data/assembly.fasta -o results/tidk
  - With a non-vertebrate motif:
      sbatch $0 -i results/asm.fasta -o results/tidk --motif TTTAGGG

REQUIRED OPTIONS:
  -i/--infile         <file>  Input genome FASTA file
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --motif             <str>   Telomeric repeat unit to search for             [default: $motif]
  --window            <int>   Window size for the repeat counts               [default: $window]
  --prefix            <str>   Output file prefix                              [default: input file basename]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<prefix>_telomeric_repeat_windows.tsv  - tidk's per-window counts:
                                                    contig, window end coordinate,
                                                    forward count, reverse count,
                                                    motif

  Alongside the tool's own output, '<outdir>/logs' will contain:
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

SOFTWARE DOCUMENTATION:
  - $TOOL_DOCS
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
version_only=false
infile=
outdir=
prefix=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --prefix )          check_val "$1" "${2:-}"; shift; prefix=$1 ;;
        --motif )           check_val "$1" "${2:-}"; shift; motif=$1 ;;
        --window )          check_val "$1" "${2:-}"; shift; window=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )      check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )  check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check software env
[[ -z "$TOOL_BINARY" ]] && die "TOOL_BINARY has not been set in this script"
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

# Print version info and exit, if requested
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! "$window" =~ ^[0-9]+$ ]] && die "--window must be a non-negative integer, not '$window'"

# Infer the prefix from the input file if it was not given
[[ -z "$prefix" ]] && prefix=$(basename "$infile" | sed -E 's/\.(fa|fasta|fna)(\.gz)?$//')

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

# Define outputs
windows_tsv="$outdir"/"$prefix"_telomeric_repeat_windows.tsv

# Record how this script was called
log_provenance "$LOG_DIR"

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
echo "Output prefix:                            $prefix"
echo "Telomeric motif:                          $motif"
echo "Window size:                              $window"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
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

log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    --string "$motif" \
    --window "$window" \
    --output "$(printf '%q' "$prefix")" \
    --dir "$(printf '%q' "$outdir")" \
    --extension tsv \
    $more_opts \
    "$(printf '%q' "$infile")"

[[ ! -s "$windows_tsv" ]] &&
    die "$TOOL_NAME did not write $windows_tsv - check the log above"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Windows with the most repeat copies (forward + reverse):"
awk -v OFS='\t' 'NR > 1 { print $1, $2, $3 + $4 }' "$windows_tsv" |
    sort -k3,3nr |
    awk 'NR <= 10 { print "  " $0 }'

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
