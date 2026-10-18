#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=omark
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Assess a predicted proteome with OMArk: completeness, but also taxonomic consistency, fragmentation and contamination - failure modes that BUSCO cannot see"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=omark
TOOL_NAME=OMArk
TOOL_DOCS=https://github.com/DessimozLab/OMArk
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
# Container has omamer 2.1.2 and omark 0.50.0
container_url=oras://community.wave.seqera.io/library/omamer_omark:50abfe0dee54ed8c
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
taxid=                              # -t: NCBI taxon ID of the species (242955 = Oneirodes acanthias)
isoform_file=                       # -i: one line per gene, isoforms separated by ';'

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

  Runs 'omamer search' first (OMArk takes its input from OMAmer), then 'omark'.
  Both come from the same Conda package / container.

  The OMAmer database ('LUCA.h5', or the smaller 'Metazoa.h5') is a separate
  download from https://omabrowser.org/oma/current/ - get it with
  download/dl-omamer.sh.

  Give it the FULL proteome and an --isoform_file: without one, OMArk counts
  every splice variant as a separate gene and the completeness figures are
  meaningless. (This is the opposite of the BUSCO run, which wants the
  longest-isoform proteome.)

  The taxonomic placement in the output is a real check, not decoration: a
  proteome placed outside Actinopterygii, or with non-trivial contamination,
  points back at the assembly rather than at the annotation.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i results/gffread/genome.protein.faa \
          -o results/omark --db /fs/scratch/PAS0471/jelmer/omamer/LUCA.h5 --taxid 242955

REQUIRED OPTIONS:
  -i/--infile         <file>  Input proteome FASTA file (all isoforms)
  -o/--outdir         <dir>   Output dir (will be created if needed)
  --db                <file>  OMAmer database ('.h5')

OTHER KEY OPTIONS:
  --taxid             <int>   NCBI taxon ID of the species                    [default: none]
  --isoform_file      <file>  Gene-to-isoform mapping, ';'-separated per line  [default: none]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<id>.omamer        - OMAmer placement of each protein
  <outdir>/*_detailed_summary.txt - completeness, consistency and contamination

  Alongside the tool's own output, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:
  --env_type          <str>   Software environment: 'conda', 'container'        [default: $env_type]
                              (Singularity/Apptainer), or 'none' (tool must
                              already be available in your PATH)
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
infile=
outdir=
db=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --db )              check_val "$1" "${2:-}"; shift; db=$1 ;;
        --taxid )           check_val "$1" "${2:-}"; shift; taxid=$1 ;;
        --isoform_file )    check_val "$1" "${2:-}"; shift; isoform_file=$1 ;;
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

# Load software
load_env   # Note: reads the env_type/conda_path/container_* globals, takes no args
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$db" ]] && die "No OMAmer database specified, do so with --db" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -f "$db" ]] && die "OMAmer database $db does not exist"
[[ -n "$isoform_file" && ! -f "$isoform_file" ]] && die "Isoform file $isoform_file does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"
file_id=$(basename "$infile" | sed -E 's/\.(faa|fa|fasta|fna)$//')
omamer_out="$outdir"/"$file_id".omamer

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
echo "Input proteome:                           $infile"
echo "Output dir:                               $outdir"
echo "OMAmer database:                          $db"
[[ -n "$taxid" ]] && echo "Taxon ID:                                 $taxid"
[[ -n "$isoform_file" ]] && echo "Isoform file:                             $isoform_file"
[[ -z "$isoform_file" ]] && echo "Isoform file:                             none - NOTE: every isoform will count as a gene"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file:"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running 'omamer search' to place each protein in the OMA hierarchy..."
runstats ${CONTAINER_PREFIX:-} omamer search \
    --db "$db" \
    --query "$infile" \
    --out "$omamer_out" \
    --nthreads "$threads"

log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    -f "$(printf '%q' "$omamer_out")" \
    -d "$(printf '%q' "$db")" \
    -o "$(printf '%q' "$outdir")" \
    ${taxid:+-t "$taxid"} \
    ${isoform_file:+-i "$(printf '%q' "$isoform_file")"} \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "OMArk summary:"
cat "$outdir"/*_detailed_summary.txt 2>/dev/null ||
    log_time "WARNING: no detailed summary file found in $outdir"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
