#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=minimap
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Map reads to a reference with Minimap2, and sort and index the output BAM with Samtools"
SCRIPT_VERSION="2026-09-24"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=minimap2
TOOL_NAME=Minimap2
TOOL_DOCS=https://github.com/lh3/minimap2
VERSION_COMMAND='minimap2 --version && ${CONTAINER_PREFIX:-} samtools --version | head -n 1'

# Defaults - generic
env_type=container          # 'conda' / 'container' / 'none'
# With minimap2 2.31 and samtools 1.24
container_url=oras://community.wave.seqera.io/library/minimap2_samtools:36e17b25d3087eff
container_dir="$HOME/containers" # Where to download a container to (if needed)
container_path=             # Full path to a pre-downloaded container image
conda_path=                 # Full path to a Conda environment to use

# Defaults - tool parameters
preset=map-ont              # Minimap2 preset ('-x')
out_format=bam              # 'bam' (sorted & indexed) or 'paf'
flagstat=true               # Run 'samtools flagstat' and 'samtools idxstats' on the BAM file

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
      sbatch $0 -i data/fastq/A.fastq.gz -r data/ref/genome.fna -o results/minimap
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i data/fastq/A.fastq.gz -r data/ref/genome.fna -o results/minimap --more_opts \"--secondary=no\"

REQUIRED OPTIONS:
  -i/--reads          <file>  Input reads (FASTQ/FASTA, can be gzipped)
  -r/--reference      <file>  Reference genome FASTA, or a Minimap2 index file ('.mmi')
                              (to avoid re-indexing a large genome for every sample,
                              create an index first with 'minimap2 -x <preset> -d ref.mmi ref.fna')
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  -x/--preset         <str>   Minimap2 preset, e.g. 'map-ont', 'lr:hq', 'map-hifi',
                              'sr', 'asm5' (see the $TOOL_NAME docs)             [default: $preset]
  --out_format        <str>   Output format: 'bam' (sorted and indexed) or 'paf' [default: $out_format]
  --prefix            <str>   Output file prefix                                [default: input file name minus extension]
  --no_flagstat               Don't run 'samtools flagstat' and 'samtools idxstats' [default: run them]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  - <outdir>/<prefix>.bam + .bam.bai   (or <prefix>.paf with '--out_format paf')
  - <outdir>/<prefix>.flagstat.txt     (unless '--no_flagstat', BAM only)
  - <outdir>/<prefix>.idxstats.txt     (unless '--no_flagstat', BAM only)
  Alongside these, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script, $TOOL_NAME, and Samtools
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
  -v/--version                Print script, $TOOL_NAME, and Samtools versions

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
reads=
reference=
outdir=
prefix=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --reads )      check_val "$1" "${2:-}"; shift; reads=$1 ;;
        -r | --reference )  check_val "$1" "${2:-}"; shift; reference=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        -x | --preset )     check_val "$1" "${2:-}"; shift; preset=$1 ;;
        --out_format )      check_val "$1" "${2:-}"; shift; out_format=$1 ;;
        --prefix )          check_val "$1" "${2:-}"; shift; prefix=$1 ;;
        --no_flagstat )     flagstat=false ;;
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
[[ -z "$reads" ]] && die "No input reads file specified, do so with -i/--reads" "$all_opts"
[[ -z "$reference" ]] && die "No reference specified, do so with -r/--reference" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$reads" ]] && die "Input reads file $reads does not exist"
[[ ! -f "$reference" ]] && die "Reference file $reference does not exist"
[[ "$out_format" != "bam" && "$out_format" != "paf" ]] &&
    die "Output format ('--out_format') should be 'bam' or 'paf' but is '$out_format'" "$all_opts"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
[[ -z "$prefix" ]] && prefix=$(basename "$reads" | sed -E 's/\.(fastq|fq|fasta|fa|fna)(\.gz)?$//')
outfile="$outdir"/"$prefix"."$out_format"
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
echo "Input reads:                              $reads"
echo "Reference:                                $reference"
echo "Output dir:                               $outdir"
echo "Output file:                              $outfile"
echo "Minimap2 preset:                          $preset"
echo "Run flagstat & idxstats?                  $flagstat"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$reads" "$reference"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env
samtools_binary="${CONTAINER_PREFIX:-} samtools"

# Run the tool
log_time "Running $TOOL_NAME..."
if [[ "$out_format" == "bam" ]]; then
    # Use (up to) 4 threads and 1 GB per thread for sorting
    sort_threads=$(( threads < 4 ? threads : 4 ))
    runstats $TOOL_BINARY \
        -x "$preset" \
        -t "$threads" \
        -a \
        $more_opts \
        "$reference" \
        "$reads" |
        $samtools_binary sort \
            -@ "$sort_threads" \
            -m 1G \
            -T "${TMPDIR:-$outdir}/$prefix.sort_tmp" \
            -o "$outfile" \
            -

    log_time "Indexing the BAM file..."
    runstats $samtools_binary index "$outfile"
else
    runstats $TOOL_BINARY \
        -x "$preset" \
        -t "$threads" \
        $more_opts \
        "$reference" \
        "$reads" \
        > "$outfile"
fi

# Mapping stats
if [[ "$flagstat" == true && "$out_format" == "bam" ]]; then
    log_time "Running samtools flagstat and idxstats..."
    $samtools_binary flagstat -@ "$threads" "$outfile" > "$outdir"/"$prefix".flagstat.txt
    $samtools_binary idxstats "$outfile" > "$outdir"/"$prefix".idxstats.txt
    log_time "Showing the samtools flagstat output:"
    cat "$outdir"/"$prefix".flagstat.txt
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
