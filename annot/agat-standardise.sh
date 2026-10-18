#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=8:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=64G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=agat-std
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Standardise a GFF/GTF file with AGAT: infer missing exon/UTR features, fix Parent relations, and sort - run this before any other GFF processing.

Afterwards, any level-2 feature typed as the generic 'transcript' (SO:0000673)
that has at least one CDS child is retyped as 'mRNA' (SO:0000234). AGAT keeps
whatever type the input used, and some gene predictors (Tiberius among them)
write 'transcript' for protein-coding models. Downstream tools key off 'mRNA'
to recognise a coding transcript, so leaving it generic is a portability
problem. Turn this off with --no_mrna_retype."
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=agat_convert_sp_gxf2gxf.pl
TOOL_NAME=AGAT
TOOL_DOCS=https://agat.readthedocs.io/en/latest/tools/agat_convert_sp_gxf2gxf.html
VERSION_COMMAND="agat --version"   # The agat_sp_*.pl scripts do not accept --version

# Defaults - tool parameters
mrna_retype=true                    # Retype CDS-bearing 'transcript' features as 'mRNA' 

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/agat:1.7.0--b5723de7d92f98e7
container_dir="$HOME/containers"
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

  This is the FIRST step of GFF post-processing: every other AGAT script assumes
  a well-formed feature hierarchy, which is exactly what this one produces.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i results/tiberius/tiberius.gff3 -o results/agat

REQUIRED OPTIONS:
  -i/--infile         <file>  Input GFF3/GTF file
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<id>.std.gff3      - the standardised annotation

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
  --no_mrna_retype            Keep the generic 'transcript' feature type
                              instead of retyping CDS-bearing transcripts
                              as 'mRNA'                                         [default: retype]
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
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )      check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )  check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        --no_mrna_retype )  mrna_retype=false ;;
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
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
file_id=$(basename "$infile" | sed -E 's/\.(gff3?|gtf)$//')
outfile="$outdir"/"$file_id".std.gff3

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
echo "Input file:                               $infile"
echo "Output dir:                               $outdir"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
echo "Output file:                               $outfile"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file:"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# agat_convert_sp_gxf2gxf.pl refuses to overwrite an existing output file, but
# only prints "File ... already exist." and still exits 0 - so a re-run would
# silently keep the old file and report success. Clear it first, then check that
# this run really wrote one.
if [[ -f "$outfile" ]]; then
    log_time "Output file $outfile already exists - removing it, because $TOOL_NAME
    would refuse to overwrite it and still exit 0"
    rm -f "$outfile"
fi

log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    -g "$(printf '%q' "$infile")" \
    -o "$(printf '%q' "$outfile")" \
    $more_opts

[[ ! -s "$outfile" ]] && die "$TOOL_NAME did not produce a non-empty $outfile"

# Retype CDS-bearing 'transcript' features as 'mRNA'. AGAT passes the input type
# through, so a predictor that writes the generic SO term keeps it, and tools
# downstream that look for 'mRNA' then miss every coding transcript.
if [[ "$mrna_retype" == true ]]; then
    retype_awk="$script_dir"/gff3-retype-mrna.awk
    [[ ! -f "$retype_awk" ]] && die "Cannot find $retype_awk - it should sit next to this script"

    log_time "Retyping CDS-bearing 'transcript' features as 'mRNA'..."
    tmp_out="$outfile".retype.tmp
    awk -f "$retype_awk" "$outfile" "$outfile" > "$tmp_out"
    mv -f "$tmp_out" "$outfile"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Feature types before and after standardisation:"
echo "--- before:"; grep -v '^#' "$infile" | cut -f3 | sort | uniq -c | sort -rn
echo "--- after:";  grep -v '^#' "$outfile" | cut -f3 | sort | uniq -c | sort -rn

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
