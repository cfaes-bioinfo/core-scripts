#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=trnascan
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Predict tRNA genes with tRNAscan-SE, then (in eukaryotic mode) run EukHighConfidenceFilter to separate likely functional tRNAs from SINE-derived copies and pseudogenes"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=tRNAscan-SE
TOOL_NAME=tRNAscan-SE
TOOL_DOCS=https://github.com/UCSC-LoweLab/tRNAscan-SE
VERSION_COMMAND="$TOOL_BINARY -h 2>&1 | grep -i -m1 tRNAscan-SE"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/trnascan-se:2.0.13--b2b03730a363c464
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
mode=E                              # Search mode: E=eukaryotic, B=bacterial, A=archaeal, O=other, M=mito
mito_model=vert                     # Mito model, only used when --mode M (see 'tRNAscan-SE -h')
hc_filter=true                      # Run EukHighConfidenceFilter afterwards (eukaryotic mode only)

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

  NOTE: run this on the UNMASKED assembly. Many tRNAs are inside repeats, so a
  soft/hard-masked genome would hide exactly what is being searched for. The
  price is a large number of SINE-derived copies and pseudogenes in the raw
  output, which is what EukHighConfidenceFilter is there to remove: report the
  raw count, but use the high-confidence set in the release.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i data/assembly.fasta -o results/trnascan

REQUIRED OPTIONS:
  -i/--infile         <file>  Input genome FASTA file (unmasked)
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --mode              <str>   Search mode: 'E' (eukaryotic), 'B', 'A', 'O', 'M' [default: $mode]
  --mito_model        <str>   Mito model, only used with '--mode M':
                              'vert', 'mammal' or 'other'                       [default: $mito_model]
  --no_hc_filter              Skip EukHighConfidenceFilter                      [default: run it]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<id>.out / .ss / .bed / .gff / .fa / .stats - raw predictions
  <outdir>/hc/<id>.out        - high-confidence set (EukHighConfidenceFilter)
  <outdir>/hc/<id>.hc.gff3    - high-confidence set as GFF3 (features + exons)

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
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --mode )            check_val "$1" "${2:-}"; shift; mode=$1 ;;
        --mito_model )      check_val "$1" "${2:-}"; shift; mito_model=$1 ;;
        --no_hc_filter )    hc_filter=false ;;
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
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
file_id=$(basename "$infile" | sed -E 's/\.(fa|fasta|fna)(\.gz)?$//')
out_txt="$outdir"/"$file_id".out
out_ss="$outdir"/"$file_id".ss
out_stats="$outdir"/"$file_id".stats
out_bed="$outdir"/"$file_id".bed
out_gff="$outdir"/"$file_id".gff
out_fa="$outdir"/"$file_id".fa
hc_dir="$outdir"/hc

# EukHighConfidenceFilter locates its input columns by header name: it dies unless
# the isotype-specific model columns are present (--detail), and it silently reads
# the sequence-name column as the 2'Str score unless -H is used too, which marks
# every real tRNA as "secondary filtered". -H cannot be combined with mito mode.
detail_opts="-H --detail"
[[ "$mode" == "M" ]] && detail_opts=

# Every mode flag stands alone except -M, which takes a model name as its argument
mode_opt="-$mode"
[[ "$mode" == "M" ]] && mode_opt="-M $mito_model"

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
echo "Search mode:                              $mode_opt"
[[ -n $detail_opts ]] && echo "Detailed-output options:                  $detail_opts"
echo "Run EukHighConfidenceFilter:              $hc_filter"
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

# NOTE: tRNAscan-SE refuses to overwrite its output files, so remove any from
#       a previous run in this dir first
rm -f "$out_txt" "$out_ss" "$out_stats" "$out_bed" "$out_gff" "$out_fa"

log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    $mode_opt \
    $detail_opts \
    --thread "$threads" \
    -o "$(printf '%q' "$out_txt")" \
    -f "$(printf '%q' "$out_ss")" \
    -m "$(printf '%q' "$out_stats")" \
    -b "$(printf '%q' "$out_bed")" \
    -j "$(printf '%q' "$out_gff")" \
    -a "$(printf '%q' "$out_fa")" \
    $more_opts \
    "$(printf '%q' "$infile")"

# The raw output is dominated by SINE-derived copies and pseudogenes in a
# repeat-rich vertebrate genome - this is what separates the plausible set
if [[ "$hc_filter" == true && "$mode" == "E" ]]; then
    log_time "Running EukHighConfidenceFilter..."
    mkdir -p "$hc_dir"
    runstats ${CONTAINER_PREFIX:-} EukHighConfidenceFilter \
        -i "$out_txt" -s "$out_ss" -o "$hc_dir" -p "$file_id"

    # EukHighConfidenceFilter writes only .out and .ss, no GFF, so recover the
    # high-confidence subset from the full GFF. The filtered .out keeps every
    # prediction and marks the surviving ones in its last column. The GFF ID is
    # the sequence name + ".trna" + the tRNA number, which are columns 1 and 2
    # of the .out (space-padded to a fixed width). Both the feature line and its
    # exon children are kept, so tRNAs with an intron come through whole.
    # NOTE: no apostrophes in this awk program, they would end the shell string
    log_time "Extracting the high-confidence tRNAs from the GFF..."
    hc_gff="$hc_dir"/"$file_id".hc.gff3
    awk -v label="high confidence set" '
        # Return the value of attribute "key" in a GFF column-9 string, or ""
        function attr(s, key,   re, v) {
            re = "(^|;)" key "=[^;]*"
            if (match(s, re)) {
                v = substr(s, RSTART, RLENGTH)
                sub("(^|;)" key "=", "", v)
                return v
            }
            return ""
        }

        BEGIN { FS = "\t"; OFS = "\t" }

        # Pass 1: the high-confidence IDs, from the filtered .out (3 header lines)
        FNR == NR {
            if (FNR <= 3) next
            if ($NF != label) next
            gsub(/ /, "", $1)
            gsub(/ /, "", $2)
            keep[$1 ".trna" $2] = 1
            n_hc++
            next
        }

        # Pass 2: the GFF, keeping each high-confidence feature and its exons
        /^##gff-version/ { print; next }
        /^#/ { next }
        {
            id = attr($9, "ID")
            par = attr($9, "Parent")
            sub(/,.*/, "", par)    # a Parent can list several comma-separated IDs
            if (id in keep || par in keep) print
        }

        END {
            if (n_hc == 0) {
                print "ERROR: no rows marked \"" label "\" in " ARGV[1] > "/dev/stderr"
                exit 1
            }
        }
    ' "$hc_dir"/"$file_id".out "$out_gff" > "$hc_gff"
elif [[ "$hc_filter" == true ]]; then
    log_time "NOTE: skipping EukHighConfidenceFilter - it only applies to eukaryotic mode (-E)"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Summary of tRNA predictions:"
echo "Raw predictions:                          $(wc -l < "$out_bed")"
if [[ -f "$hc_dir"/"$file_id".out ]]; then
    echo "High-confidence tRNAs:                    $(tail -n +4 "$hc_dir"/"$file_id".out | wc -l)"
fi
log_time "Counts per isotype (raw):"
tail -n +4 "$out_txt" | awk '{print $5}' | sort | uniq -c | sort -rn

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
