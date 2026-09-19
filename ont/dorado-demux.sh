#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --gpus-per-node=2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=FAIL
#SBATCH --job-name=dorado-demux
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Demultiplex basecalled ONT reads with Dorado"
SCRIPT_VERSION="2026-09-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="/fs/ess/PAS0471/software/dorado/dorado-2.1.2-linux-x64/bin/dorado"
TOOL_NAME=Dorado
TOOL_DOCS=https://github.com/nanoporetech/dorado
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=none                      # Dorado is run from a fixed absolute path (not Conda/container);
                                   # 'none' just tells load_env()/final_reporting() to skip both

# Constants - tool parameters
EMIT_FASTQ="--emit-fastq"          # Output FASTQ instead of SAM

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
      sbatch $0 -i results/dorado -o results/dorado_demux --kit SQK-RPB114-24

REQUIRED OPTIONS:
-i/--input          <file>  Input file, or dir with FASTQ or BAM files
-o/--outdir         <dir>   Output dir (will be created if needed)
                            One gzipped FASTQ file per barcode will be
                            written directly into this dir (any per-sample/
                            per-run subdirs that $TOOL_NAME creates are
                            flattened away), along with a read-count table
                            'barcode_read_counts.tsv'
--kit               <str>   Barcode kit, e.g. SQK-RPB114-24

OTHER KEY OPTIONS:
--barcodes          <file>  File with one barcode ID to keep per line
                            (e.g. 'barcode01'/'unclassified'), one per line.
                            When not provided, all barcodes are kept.
--more_opts         <str>   Quoted string with one or more additional options
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
kit=
barcode_list=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --input )      check_val "$1" "${2:-}"; shift; input=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --kit )             check_val "$1" "${2:-}"; shift; kit=$1 ;;
        --barcodes )        check_val "$1" "${2:-}"; shift; barcode_list=$1 ;;
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
[[ -z "$kit" ]] && die "No barcode kit specified, do so with --kit" "$all_opts"
[[ -n "$barcode_list" && ! -f "$barcode_list" ]] && die "Barcode list file $barcode_list does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

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
echo "Output dir:                               $outdir"
echo "Barcode kit name:                         $kit"
[[ -n $barcode_list ]] && echo "Barcode list file:                        $barcode_list"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$input"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" demux \
    --kit-name "$kit" \
    "$EMIT_FASTQ" \
    --output-dir "$outdir" \
    --threads "$threads" \
    $more_opts \
    "$input"

log_time "Consolidating output FASTQ files into $outdir..."
# $TOOL_NAME nests its output in per-sample/per-run subdirs, e.g.
# <outdir>/<sample>/.../fastq_pass/barcodeNN/*.fastq -- pull all barcode dirs'
# FASTQ files directly into $outdir, concatenating across any such subdirs
declare -A bc_seen=()
while IFS= read -r -d '' bc_dir; do
    bc=$(basename "$bc_dir")
    if [[ -z "${bc_seen[$bc]:-}" ]]; then
        cat "$bc_dir"/*.fastq > "$outdir"/"$bc".fastq
        bc_seen[$bc]=1
    else
        cat "$bc_dir"/*.fastq >> "$outdir"/"$bc".fastq
    fi
done < <(find "$outdir" -mindepth 1 -type d \( -name "barcode*" -o -name "unclassified" \) -print0 | sort -z)

# Remove the now-redundant nested dirs (everything except the log dir and the flat FASTQ files)
# NOTE: compare by name, not against $LOG_DIR, since that path is absolute while
#       $outdir (and thus the paths find reports here) may be relative
find "$outdir" -mindepth 1 -maxdepth 1 -type d -not -name "$(basename "$LOG_DIR")" -exec rm -rf {} +

# Keep only the requested barcodes, if a barcode list was provided
if [[ -n "$barcode_list" ]]; then
    log_time "Keeping only the barcodes listed in $barcode_list..."
    for fq in "$outdir"/*.fastq; do
        [[ -e "$fq" ]] || continue
        bc=$(basename "$fq" .fastq)
        grep -qxF "$bc" "$barcode_list" || rm -f "$fq"
    done
fi

log_time "Gzipping the output FASTQ files..."
find "$outdir" -maxdepth 1 -name "*.fastq" | while read -r fq; do
    gzip -cv "$fq" > "$outdir"/"$(basename "$fq")".gz
    rm -f "$fq"
done

# Create a table with the number of reads assigned to each barcode
log_time "Counting reads per barcode..."
count_table="$outdir"/barcode_read_counts.tsv
{
    echo -e "barcode\tn_reads"
    for fq in "$outdir"/*.fastq.gz; do
        [[ -e "$fq" ]] || continue
        bc=$(basename "$fq" .fastq.gz)
        n_reads=$(( $(zcat "$fq" | wc -l) / 4 ))
        echo -e "$bc\t$n_reads"
    done | sort -k1,1V
} > "$count_table"
log_time "Read counts per barcode (also saved in $count_table):"
column -t "$count_table"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
