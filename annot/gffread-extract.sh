#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=gffread
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Extract CDS, protein and spliced-transcript FASTA files from a GFF3 annotation plus its genome, with gffread; also reports how many models have in-frame stops or lack a valid start/stop"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=gffread
TOOL_NAME=gffread
TOOL_DOCS=https://github.com/gpertea/gffread
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/gffread:0.12.9--6218c789425eee86
container_dir="$HOME/containers"
container_path=
conda_path=

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

  The sequences are extracted WITHOUT '-J'/'-V', so the FASTA files match the
  input GFF3 one-to-one and nothing is dropped silently. Those two flags are
  used separately, in a second pass, purely to COUNT problem models - decide what
  to do about them from that count rather than filtering them away here.

  Tiberius should produce almost no such models. A non-trivial count means
  something is wrong upstream (wrong genome version, coordinate offset) and
  should be diagnosed, not filtered.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i results/agat/tiberius.std.gff3 \
          -g data/assembly.fasta \
          -o results/gffread --prefix genome

REQUIRED OPTIONS:
  -i/--infile         <file>  Input GFF3 file
  -g/--genome         <file>  Genome FASTA the GFF3 refers to
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --prefix            <str>   Basename for the output files                   [default: from the input file name]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<prefix>.cds.fna         - CDS nucleotide sequences
  <outdir>/<prefix>.protein.faa     - protein sequences ('*' as the stop codon)
  <outdir>/<prefix>.transcript.fna  - spliced transcript sequences

  Alongside the tool's own output, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)
    <prefix>.valid-check.gff3 - '-J -V' pass, used only for the count below;
                                a diagnostic byproduct, not a release file

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
genome=
outdir=
prefix=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -g | --genome )     check_val "$1" "${2:-}"; shift; genome=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --prefix )          check_val "$1" "${2:-}"; shift; prefix=$1 ;;
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
[[ -z "$infile" ]] && die "No input GFF3 specified, do so with -i/--infile" "$all_opts"
[[ -z "$genome" ]] && die "No genome FASTA specified, do so with -g/--genome" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input GFF3 $infile does not exist"
[[ ! -f "$genome" ]] && die "Genome FASTA $genome does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
[[ -z "$prefix" ]] && prefix=$(basename "$infile" | sed -E 's/\.(gff3?|gtf)$//')
cds_out="$outdir"/"$prefix".cds.fna
prot_out="$outdir"/"$prefix".protein.faa
tx_out="$outdir"/"$prefix".transcript.fna
check_gff="$LOG_DIR"/"$prefix".valid-check.gff3

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
echo "Input GFF3:                               $infile"
echo "Genome FASTA:                             $genome"
echo "Output dir:                               $outdir"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
echo "Output prefix:                            $prefix"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input files:"
ls -lh "$infile" "$genome"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# Fail early and clearly on the classic silent-empty-output cause
log_time "Checking that the GFF3 and the genome use the same sequence IDs..."
n_shared=$(comm -12 \
    <(grep -v '^#' "$infile" | cut -f1 | sort -u) \
    <(grep '^>' "$genome" | sed 's/^>//; s/[[:space:]].*//' | sort -u) | wc -l)
[[ "$n_shared" -eq 0 ]] &&
    die "No sequence IDs are shared between $infile and $genome - gffread would produce empty output"
echo "Sequence IDs shared between GFF3 and genome: $n_shared"

log_time "Running $TOOL_NAME to extract the sequences..."
eval runstats "$TOOL_BINARY" \
    "$(printf '%q' "$infile")" \
    -g "$(printf '%q' "$genome")" \
    -x "$(printf '%q' "$cds_out")" \
    -y "$(printf '%q' "$prot_out")" \
    -w "$(printf '%q' "$tx_out")" \
    -S \
    $more_opts

# Second pass, for counting only: '-J' keeps only mRNAs with a valid start and
# stop codon, '-V' discards models with in-frame stop codons
log_time "Running $TOOL_NAME again with '-J -V', to count problem models..."
eval runstats "$TOOL_BINARY" \
    "$(printf '%q' "$infile")" \
    -g "$(printf '%q' "$genome")" \
    -J -V \
    -o "$(printf '%q' "$check_gff")"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
n_in=$(awk '$3 == "mRNA" || $3 == "transcript"' "$infile" | wc -l)
n_ok=$(awk '$3 == "mRNA" || $3 == "transcript"' "$check_gff" | wc -l)
log_time "Model validity check:"
echo "Transcripts in the input GFF3:            $n_in"
echo "Transcripts passing '-J -V':              $n_ok"
echo "Transcripts with a broken CDS:            $(( n_in - n_ok ))"
log_time "Number of sequences written:"
echo "CDS:                                      $(grep -c '^>' "$cds_out")"
echo "Proteins:                                 $(grep -c '^>' "$prot_out")"
echo "Transcripts:                              $(grep -c '^>' "$tx_out")"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
