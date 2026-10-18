#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=4:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=liftoff
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="
Run Liftoff to transfer gene annotations from a reference assembly to a target assembly.
Always runs with options -copies and -polish."
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=liftoff
TOOL_NAME=Liftoff
TOOL_DOCS=https://github.com/agshumate/Liftoff
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=container          # 'conda' / 'container' / 'none'
container_url=oras://community.wave.seqera.io/library/liftoff_liftofftools:7a69d821dc62677b
container_dir="$HOME/containers" # Where to download a container to (if needed)
container_path=             # Full path to a pre-downloaded container image
conda_path=

# Constants - tool parameters
# Always runs with options -copies and -polish

# Defaults - tool parameters
coverage=0.5                    # Same as liftoff default
sequence_identity=0.5           # Same as liftoff default
exclude_partial=false

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
      sbatch $0 \\
          -i results/asm/novel_genome.fa \\
          --ref_fasta data/ref/soybase/glyma.Wm82.gnm1.FCtY.genome_main.fna \\
          --ref_gff data/ref/soybase/glyma.Wm82.gnm1.ann1.DvBy.gene_models_main.gff3 \\
          -o results/liftoff/novel_from_v1
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i novel_genome.fa --ref_fasta ref.fna --ref_gff ref.gff3 \\
          -o results/liftoff --more_opts \"--some-opt 'a value'\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Target assembly FASTA (novel genome)
  --ref_fasta         <file>  Reference assembly FASTA used by the source annotation
  --ref_gff           <file>  Reference annotation GFF/GTF to transfer
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --coverage          <float> Minimum feature coverage (-a)                     [default: $coverage]
  --sequence_identity <float> Minimum sequence identity (-s)                    [default: $sequence_identity]
  --exclude_partial           Pass Liftoff -exclude_partial
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
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
ref_fasta=
ref_gff=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        --ref_fasta )       check_val "$1" "${2:-}"; shift; ref_fasta=$1 ;;
        --ref_gff )         check_val "$1" "${2:-}"; shift; ref_gff=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --coverage )        check_val "$1" "${2:-}"; shift; coverage=$1 ;;
        --sequence_identity ) check_val "$1" "${2:-}"; shift; sequence_identity=$1 ;;
        --exclude_partial ) exclude_partial=true ;;
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

# Print version info and exit, if requested (this needs the software env loaded)
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$ref_fasta" ]] && die "No reference FASTA specified, do so with --ref_fasta" "$all_opts"
[[ -z "$ref_gff" ]] && die "No reference GFF specified, do so with --ref_gff" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -f "$ref_fasta" ]] && die "Input file $ref_fasta does not exist"
[[ ! -f "$ref_gff" ]] && die "Input file $ref_gff does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Make file paths absolute, because the script moves into the output dir
infile=$(realpath "$infile")
ref_fasta=$(realpath "$ref_fasta")
ref_gff=$(realpath "$ref_gff")
outdir=$(realpath -m "$outdir")

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

target_base=$(basename "$infile")
target_base=${target_base%.gz}
target_base=${target_base%.*}
out_gff_path="$outdir"/"$target_base".liftoff.gff3
unmapped_path="$outdir"/"$target_base".liftoff.unmapped.txt

intermediate_dir="$outdir"/intermediate_files

# Optional argument snippets
exclude_partial_opt=
[[ "$exclude_partial" == true ]] && exclude_partial_opt="-exclude_partial"

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
echo "Target assembly FASTA:                    $infile"
echo "Reference assembly FASTA:                 $ref_fasta"
echo "Reference annotation GFF:                 $ref_gff"
echo "Output dir:                               $outdir"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
echo "Lifted annotation output:                 $out_gff_path"
echo "Unmapped features output:                 $unmapped_path"
echo "Minimum coverage (-a):                    $coverage"
echo "Minimum sequence identity (-s):           $sequence_identity"
echo "Exclude partial mappings:                 $exclude_partial"
echo "Map extra copies:                         true"
echo "Polish lifted annotation:                 true"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile" "$ref_fasta" "$ref_gff"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# Run the tool from within the output dir
cd "$outdir" || die "Can't change to output dir $outdir"

log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    "$(printf '%q' "$infile")" \
    "$(printf '%q' "$ref_fasta")" \
    -g "$(printf '%q' "$ref_gff")" \
    -o "$(printf '%q' "$out_gff_path")" \
    -u "$(printf '%q' "$unmapped_path")" \
    -dir "$(printf '%q' "$intermediate_dir")" \
    -p "$threads" \
    -a "$coverage" \
    -s "$sequence_identity" \
    $exclude_partial_opt \
    -copies \
    -polish \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$outdir"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
