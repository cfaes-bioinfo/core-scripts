#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=cutadapt
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Screen PacBio HiFi reads for residual SMRTbell adapter/primer sequences with Cutadapt, discarding affected reads entirely (as HiFiAdapterFilt does)"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=cutadapt
TOOL_NAME=Cutadapt
TOOL_DOCS=https://cutadapt.readthedocs.io
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=container                  # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/cutadapt:5.2--7e96173061760bf9
conda_path=
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters
# The PacBio SMRTbell adapter and primer sequences (NCBI UniVec accessions),
# i.e. the same two sequences HiFiAdapterFilt BLASTs against. Both strands are
# listed because Cutadapt's '-b' searches only for the sequence as given -
# neither adapter is its own reverse complement.
ADAPTER_BLUNT_FWD=ATCTCTCTCTTTTCCTCCTCCTCCGTTGTTGTTGTTGAGAGAGAT   # NGB00972.1, 45 bp, Blunt Adapter
ADAPTER_BLUNT_REV=ATCTCTCTCAACAACAACAACGGAGGAGGAGGAAAAGAGAGAGAT   # NGB00972.1, reverse complement
ADAPTER_C2_FWD=AAAAAAAAAAAAAAAAAATTAACGGAGGAGGAGGA               # NGB00973.1, 35 bp, C2 Primer
ADAPTER_C2_REV=TCCTCCTCCTCCGTTAATTTTTTTTTTTTTTTTTT               # NGB00973.1, reverse complement

# Defaults - tool parameters
# The defaults reproduce HiFiAdapterFilt's criteria: a match of >=44 bp at >=97%
# identity to the blunt adapter, or >=34 bp at >=97% to the C2 primer.
# NOTE: the C2 primer starts with 18 A's, so a shorter minimum match would flag
#       every read with a poly-A tract.
min_overlap_blunt=44                # Min. match length for the blunt adapter
min_overlap_c2=34                   # Min. match length for the C2 primer
max_error_rate=0.03                 # Max. error rate (0.03 = >=97% identity)

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

Reads matching an adapter are not trimmed but removed in full, because a
remnant SMRTbell adapter inside a HiFi read marks that read as potentially
chimeric. The reads that were removed are kept in a separate FASTQ file so
they can be inspected.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i results/bam2fastq/sample.fastq.gz -o results/cutadapt
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i results/bam2fastq/sample.fastq.gz -o results/cutadapt --more_opts \"--some-opt 'a value'\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input HiFi reads (.fastq(.gz) or .fq(.gz))
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --min-overlap-blunt <int>   Min. match length for the blunt adapter          [default: $min_overlap_blunt]
  --min-overlap-c2    <int>   Min. match length for the C2 primer              [default: $min_overlap_c2]
  --max-error-rate    <num>   Max. error rate, e.g. 0.03 for >=97% identity    [default: $max_error_rate]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<sample>.filt.fastq.gz       - The adapter-free reads (use these downstream)
  <outdir>/<sample>.adapter-reads.fastq.gz  - The reads that were removed
  Alongside those, '<outdir>/logs' will contain:
    tool_output.log   - $TOOL_NAME's own report
    <sample>.cutadapt.json - The same report in JSON format
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
infile=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )             check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )             check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --min-overlap-blunt )       check_val "$1" "${2:-}"; shift; min_overlap_blunt=$1 ;;
        --min-overlap-c2 )          check_val "$1" "${2:-}"; shift; min_overlap_c2=$1 ;;
        --max-error-rate )          check_val "$1" "${2:-}"; shift; max_error_rate=$1 ;;
        --more_opts )               check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )                check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )              check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )           check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )           check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )          check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )               script_help; exit 0 ;;
        -v | --version)             version_only=true ;;
        * )                         die "Invalid option $1" "$all_opts" ;;
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

sample=$(basename "$infile" | sed -E 's/\.(fastq|fq)(\.gz)?$//')
clean_fq="$outdir"/"$sample".filt.fastq.gz            # Reads without adapters
adapter_fq="$outdir"/"$sample".adapter-reads.fastq.gz # Reads that were removed
tool_log="$LOG_DIR"/tool_output.log
json_report="$LOG_DIR"/"$sample".cutadapt.json        # Extension is required by Cutadapt

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
echo "Sample name:                              $sample"
echo "Min. match length, blunt adapter:         $min_overlap_blunt"
echo "Min. match length, C2 primer:             $min_overlap_c2"
echo "Max. error rate:                          $max_error_rate"
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

# Build the adapter options: '-b' searches for the adapter anywhere in the read
# (5' end, 3' end, or internal), and the ';'-separated suffixes set the match
# stringency per adapter
adapter_opts=
for adapter in "$ADAPTER_BLUNT_FWD;min_overlap=$min_overlap_blunt;e=$max_error_rate" \
               "$ADAPTER_BLUNT_REV;min_overlap=$min_overlap_blunt;e=$max_error_rate" \
               "$ADAPTER_C2_FWD;min_overlap=$min_overlap_c2;e=$max_error_rate" \
               "$ADAPTER_C2_REV;min_overlap=$min_overlap_c2;e=$max_error_rate"; do
    adapter_opts+=" -b $(printf '%q' "$adapter")"
done

# Run the tool
# NOTE: '--action=none' leaves matching reads untouched, but they still count as
#       "trimmed", so '--untrimmed-output' collects the adapter-free reads while
#       '-o' collects the removed ones with their sequences intact
log_time "Running $TOOL_NAME on $infile..."
eval runstats "$TOOL_BINARY" \
    --action=none \
    $adapter_opts \
    --untrimmed-output "$(printf '%q' "$clean_fq")" \
    --output "$(printf '%q' "$adapter_fq")" \
    --json "$(printf '%q' "$json_report")" \
    --cores "$threads" \
    $more_opts \
    "$(printf '%q' "$infile")" \
    2>&1 | tee "$tool_log"

# Don't trust the exit status alone: a truncated or missing report means the
# screen did not actually run over the whole read set
[[ ! -s "$tool_log" ]] &&
    die "$TOOL_NAME's output log $tool_log is missing or empty - the run could not be verified" "$all_opts"
[[ ! -s "$clean_fq" ]] &&
    die "The filtered FASTQ $clean_fq is missing or empty" "$all_opts"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Summary of the adapter screen:"
grep -E "Total reads processed|Reads with adapters" "$tool_log" ||
    log_time "WARNING: could not find the read counts in $tool_log"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
