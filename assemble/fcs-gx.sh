#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=4:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=512G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=fcs-gx
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Screen a genome assembly for foreign contamination with NCBI FCS-GX"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="run_gx.py"
TOOL_NAME=FCS-GX
TOOL_DOCS="https://github.com/ncbi/fcs/wiki/FCS-GX"
VERSION_COMMAND="gx --help | grep build:"

# Defaults - generic
env_type=container
container_url=oras://community.wave.seqera.io/library/ncbi-fcs-gx:0.5.5--b6aa06d4ea025283
conda_path=
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters
#  FCS-GX memory-maps the whole ~470 GB database, so it needs a large-memory
#  host. On Pitzer the largemem nodes are in the default 'batch' partition, so
#  the '--mem' above is enough to land on one.

# Defaults - tool parameters
tax_id=
gx_db=
out_basename=

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

This runs the *screen* step only: it writes an action report and leaves the
assembly untouched. Applying the report (FCS-GX's 'clean genome' step) is a
separate decision, so that its calls can first be compared against whatever
other evidence you have.

Run this on the RAW assembly, before removing anything by hand. FCS-GX is an
independent line of evidence, and a screen of an already-filtered assembly can
only find contigs you missed - never ones you removed by mistake.

The action report classifies sequences as EXCLUDE, TRIM or FIX (which FCS-GX
would clean automatically) and REVIEW, REVIEW_RARE or INFO (lower confidence,
left for you to judge).

USAGE / EXAMPLE COMMANDS:
  - Basic usage:
      sbatch $0 -i results/hifiasm/asm.bp.p_ctg.fasta \\
          -o results/fcs-gx --gx_db /fs/scratch/PAS0471/\$USER/fcs-gx-db --tax_id 206105
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i ... -o ... --gx_db ... --tax_id ... --more_opts \"--split-fasta\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input assembly FASTA
  -o/--outdir         <dir>   Output dir (will be created if needed)
  --gx_db             <dir>   Dir with the FCS-GX database (see fcs-gx-download.sh)
  --tax_id            <int>   NCBI taxon ID of the expected organism

OTHER KEY OPTIONS:
  --out_basename      <str>   Prefix for the output files                        [default: input file basename]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<basename>.<tax_id>.fcs_gx_report.txt  - The action report
  <outdir>/<basename>.<tax_id>.taxonomy.rpt       - Per-sequence taxonomy detail
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

TOOL DOCUMENTATION: $TOOL_DOCS
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
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --gx_db )           check_val "$1" "${2:-}"; shift; gx_db=$1 ;;
        --tax_id )          check_val "$1" "${2:-}"; shift; tax_id=$1 ;;
        --out_basename )    check_val "$1" "${2:-}"; shift; out_basename=$1 ;;
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
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$gx_db" ]] && die "No FCS-GX database specified, do so with --gx_db" "$all_opts"
[[ -z "$tax_id" ]] && die "No taxon ID specified, do so with --tax_id" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -d "$gx_db" ]] && die "FCS-GX database dir $gx_db does not exist"
[[ ! "$tax_id" =~ ^[0-9]+$ ]] &&
    die "--tax_id should be a positive integer but is '$tax_id'" "$all_opts"

# The DB dir should hold the actual database, not just the download logs
if ! compgen -G "$gx_db"/*.gxi > /dev/null; then
    die "No '.gxi' index found in $gx_db - is the database download complete?"
fi

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
[[ -z "$out_basename" ]] && out_basename=$(basename "${infile%.*}")
REPORT="$outdir/$out_basename.$tax_id.fcs_gx_report.txt"

# FCS-GX takes its thread count from an env var rather than an option
set_threads "$IS_SLURM"
export GX_NUM_CORES="$threads"

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
echo "Input assembly:                           $infile"
echo "Output dir:                               $outdir"
echo "FCS-GX database:                          $gx_db"
echo "Taxon ID:                                 $tax_id"
echo "Output basename:                          $out_basename"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# Run the tool
log_time "Running $TOOL_NAME (this loads the ~470 GB database into memory first)..."
eval runstats "$TOOL_BINARY" \
    --fasta "$infile" \
    --gx-db "$gx_db" \
    --tax-id "$tax_id" \
    --out-basename "$out_basename" \
    --out-dir "$outdir" \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
# Summarize the action report, so that agreement or disagreement with any
# existing contaminant calls is visible without opening the file
if [[ -f "$REPORT" ]]; then
    log_time "Sequences per action in $(basename "$REPORT"):"
    awk -F'\t' '!/^#/ && NF > 1 { n[$5]++ } END { for (a in n) printf "  %-14s %d\n", a, n[a] }' \
        "$REPORT" | sort -k2 -rn

    log_time "All flagged sequences (action, length, contaminant assignment):"
    awk -F'\t' '!/^#/ && NF > 1 { printf "  %-14s %-14s %10s bp   %s\n", $1, $5, $4, $8 }' \
        "$REPORT" | sort -k2,2 -k3,3rn
else
    log_time "WARNING: No action report found at $REPORT"
fi

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
log_time "NOTE: this only screened the assembly - nothing was removed"
final_reporting
