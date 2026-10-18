#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=40
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=cmscan
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Search a genome (or one chunk of it) against the Rfam covariance-model
database with Infernal cmscan, to annotate non-coding RNA families"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=cmscan
TOOL_NAME="Infernal cmscan"
TOOL_DOCS=https://docs.rfam.org/en/latest/genome-annotation.html
VERSION_COMMAND="$TOOL_BINARY -h 2>&1 | grep -i -m1 INFERNAL"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/infernal:1.1.5--6127a3d16c7cb208
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
clanin=                             # --clanin file; defaults to Rfam.clanin next to --db
genome_mb=                          # Genome size in Mb - '-Z' is set to 2x this (both strands)
noali=true                          # Pass --noali (the .tblout is what is used downstream)

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

  Split the assembly first (convert/seqkit-split.sh), then submit one job per
  chunk with -i/--infile - loop over the chunks in the runner script (a plain 'for'
  loop calling sbatch once per chunk), not with a Slurm array. Rfam's published
  rates for large eukaryotic genomes in this mode are 4.8 Mb/h (human) to
  6.1 Mb/h (pig), so a ~700 Mb genome is ~110-150 CPU-hours in total and a
  ~36 Mb contig is under two hours of wall time on 40 cores. Time one small
  contig first to confirm the rate holds here, rather than sizing --time from
  a guess.

  '-Z' must be 2x the size of the WHOLE genome in Mb (both strands), even when
  scanning a single chunk - otherwise E-values are not comparable between
  chunks. Pass the genome size with --genome_mb and this script doubles it.

  Run on the UNMASKED assembly: many ncRNAs sit inside repeats.

  AFTERWARDS: concatenate the per-chunk .tblout files, and drop the rows marked
  '=' in the 'olp' column - those are lower-scoring hits that overlap a better
  hit from the same Rfam clan. Then convert to GFF3 with
  'infernal-tblout2gff.pl --cmscan --fmt2'.

USAGE / EXAMPLE COMMANDS:
  - On a single FASTA file - a whole genome, or one pre-split chunk of one
    (loop over chunks to submit one job per chunk):
      sbatch $0 -i results/chunks/assembly.part_001.fasta -o results/cmscan \
          --db \$rfam_db/Rfam.cm --genome_mb 650

REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTA file (a whole genome, or one chunk)
  --db                <file>  Rfam covariance-model file, indexed with cmpress
                              (create with download/dl-rfam.sh)
  --genome_mb         <num>   Size of the WHOLE genome in Mb (not of the chunk)
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --clanin            <file>  Rfam clan file                                  [default: Rfam.clanin next to --db]
  --keep_alignments           Don't pass '--noali' (keeps full alignments in the
                              main output, which gets very large)               [default: --noali]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<chunk>.tblout     - tabular hits ('--fmt 2', so it has the 'olp' column)
  <outdir>/<chunk>.cmscan     - the main human-readable output

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
        --clanin )          check_val "$1" "${2:-}"; shift; clanin=$1 ;;
        --genome_mb )       check_val "$1" "${2:-}"; shift; genome_mb=$1 ;;
        --keep_alignments ) noali=false ;;
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
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$db" ]] && die "No Rfam CM database specified, do so with --db" "$all_opts"
[[ -z "$genome_mb" ]] && die "No genome size specified, do so with --genome_mb" "$all_opts"
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -f "$db" ]] && die "Rfam CM file $db does not exist"
[[ ! -f "$db".i1m ]] &&
    die "$db has not been indexed with cmpress (no $db.i1m) - run download/dl-rfam.sh"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

# Default the clan file to the one sitting next to the CM database
[[ -z "$clanin" ]] && clanin=$(dirname "$db")/Rfam.clanin
[[ ! -f "$clanin" ]] && die "Rfam clan file $clanin does not exist, specify one with --clanin"

# '-Z' is the search space in Mb, counting BOTH strands of the whole genome
z_value=$(awk -v g="$genome_mb" 'BEGIN{printf "%.1f", g * 2}')

chunk_id=$(basename "$infile" | sed -E 's/\.(fa|fasta|fna)(\.gz)?$//')
out_tbl="$outdir"/"$chunk_id".tblout
out_main="$outdir"/"$chunk_id".cmscan
[[ "$noali" == true ]] && noali_opt="--noali" || noali_opt=

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
echo "Rfam CM database:                         $db"
echo "Rfam clan file:                           $clanin"
echo "Genome size (Mb):                         $genome_mb"
echo "Search space passed to -Z (2x genome):    $z_value"
echo "Pass --noali:                             $noali"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file:"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    -Z "$z_value" \
    --cut_ga \
    --rfam \
    --nohmmonly \
    --fmt 2 \
    --cpu "$threads" \
    --clanin "$(printf '%q' "$clanin")" \
    --tblout "$(printf '%q' "$out_tbl")" \
    $noali_opt \
    $more_opts \
    "$(printf '%q' "$db")" \
    "$(printf '%q' "$infile")" \
    > "$out_main"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Number of hits for this chunk:"
n_all=$(grep -vc '^#' "$out_tbl" || true)
# Column 20 of '--fmt 2' is 'olp': '=' marks a hit that overlaps a better-scoring
# hit from the same clan, and should be dropped when merging the chunks
n_kept=$(awk '!/^#/ && $20 != "=" ' "$out_tbl" | wc -l)
echo "All hits:                                 $n_all"
echo "After dropping same-clan overlaps ('='):  $n_kept"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
