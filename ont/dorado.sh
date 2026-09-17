#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00      # NOTE: duplex calling is slower than simplex - increase this via `sbatch --time=...` when using --duplex
#SBATCH --gpus-per-node=2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=FAIL
#SBATCH --job-name=dorado
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Basecall ONT reads (FAST5 or POD5) with Dorado using GPUs and output FASTQ or BAM files"
SCRIPT_VERSION="2026-09-17"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="/fs/ess/PAS0471/software/dorado/dorado-1.3.1-linux-x64/bin/dorado"
TOOL_NAME=Dorado
TOOL_DOCS=https://github.com/nanoporetech/dorado
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=none                      # Dorado is run from a fixed absolute path (not Conda/container);
                                   # 'none' just tells load_env()/final_reporting() to skip both

# Defaults - tool parameters
model=sup                          # Basecalling model: fast, hac, or sup -- can be fast@<version> to specify kit
out_format=fastq                   # Output file format: 'fastq' or 'bam'
trim=all                           # What to trim from the reads (simplex only). Dorado default. Options: 'adapters', 'none', 'all'
out_format_opt="--emit-fastq"      # (This option will be updated automatically based on out_format)
duplex=false                       # When true, run 'dorado duplex' instead of 'dorado basecaller'
pairs=                             # Optional (--duplex only): CSV file with read ID pairs; auto-paired if not given

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
  - Basic usage example (simplex basecalling):
      sbatch $0 -i data/pod5 -o results/dorado
  - Duplex basecalling (needs POD5 input, and more time - increase --time):
      sbatch --time=8:00:00 $0 -i data/pod5 -o results/dorado_duplex --duplex

REQUIRED OPTIONS:
-i/--input          <file>  Input file or dir;
                            files should be in FAST5 or POD5 format
                            (--duplex requires POD5).
                            When using FAST5, the base-calling model
                            (--model) must include the kit.
-o/--outdir         <dir>   Output dir (will be created if needed)
                            Regardless of the number of input files,
                            the output will be a single file:
                            - In case of a single input file, the output file
                              will have the same name as the input file
                            - In case of multiple input files, the output file
                              will have the same name as the input dir

OTHER KEY OPTIONS:
--model             <str>   Basecall model                                      [default: $model]
--trim              <str>   Trim adapters, options: 'adapters',
                            'none', 'all'  (= adapters + primers + barcodes)
                            (Simplex basecalling only, ignored with --duplex)    [default: $trim]
--out_format        <str>   Output file format, 'bam' or 'fastq'                [default: $out_format]
--duplex                    Run duplex (double-strand) calling instead of
                            simplex calling ('dorado duplex' instead of
                            'dorado basecaller'). Needs POD5 input, and
                            barcode demultiplexing (see dorado-demux.sh)        [default: $duplex]
--pairs             <file>  CSV file with read ID pairs (--duplex only);
                            when not provided, Dorado will auto-pair reads      [default: off]

  --more_opts       <str>   Quoted string with one or more additional options
                            for $TOOL_NAME

UTILITY OPTIONS:
  -h/--help                 Print this help message
  -v/--version              Print script and $TOOL_NAME versions

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
input=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --input )      check_val "$1" "${2:-}"; shift; input=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --model )           check_val "$1" "${2:-}"; shift; model=$1 ;;
        --trim )            check_val "$1" "${2:-}"; shift; trim=$1 ;;
        --out_format )      check_val "$1" "${2:-}"; shift; out_format=$1 ;;
        --duplex )          duplex=true ;;
        --pairs )           check_val "$1" "${2:-}"; shift; pairs=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
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
[[ -z "$input" ]] && die "No input file/dir specified, do so with -i/--input" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$input" && ! -d "$input" ]] && die "Input file/dir $input does not exist"
[[ "$out_format" != "bam" && "$out_format" != "fastq" ]] && die "Output format should be 'fastq' or 'bam', not $out_format"
[[ -n "$pairs" && "$duplex" == false ]] && die "--pairs was specified, but that option is only used with --duplex" "$all_opts"
[[ "$duplex" == true && -f "$input" && "$input" != *.pod5 ]] && die "Duplex calling (--duplex) needs POD5 input, but $input is not a POD5 file"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
[[ "$out_format" == "bam" ]] && out_format_opt=
[[ -f "$input" ]] && outfile="$outdir"/$(basename "${input%.*}").$out_format
[[ -d "$input" ]] && outfile="$outdir"/$(basename "$input").$out_format
pairs_opt=
[[ -n "$pairs" ]] && printf -v pairs_opt -- "--pairs %q" "$pairs"

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
echo "Input file or dir:                        $input"
echo "Output file:                              $outfile"
echo "Output format:                            $out_format"
echo "Base-calling model:                       $model"
echo "Duplex calling:                           $duplex"
[[ "$duplex" == true ]] && echo "Pairs file:                                ${pairs:-<auto-pair>}"
[[ "$duplex" == false ]] && echo "Trimming option:                          $trim"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$input"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

if [[ "$duplex" == true ]]; then
    log_time "Running $TOOL_NAME duplex calling..."
    eval runstats "$TOOL_BINARY" duplex \
        $out_format_opt \
        "$pairs_opt" \
        --threads "$threads" \
        $more_opts \
        "$model" \
        "$input" \
        > "$outfile"
else
    log_time "Running $TOOL_NAME simplex calling..."
    eval runstats "$TOOL_BINARY" basecaller \
        $out_format_opt \
        $more_opts \
        "$model" \
        "$input" \
        --trim "$trim" \
        > "$outfile"
fi

# Dorado options
#? -x, --device // device string in format "cuda:0,...,N", "cuda:all", "metal", "cpu" etc.. [default: "cuda:all"]

if [[ "$out_format" == "fastq" ]]; then
    log_time "Zipping up the output FASTQ file..."
    runstats gzip -f "$outfile"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing the output file:"
ls -lh "$outfile".gz 2>/dev/null || ls -lh "$outfile"
final_reporting
