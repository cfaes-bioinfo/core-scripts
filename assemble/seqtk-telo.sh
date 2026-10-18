#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=seqtk-telo
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Find telomeric arrays that reach the sequence termini themselves, with 'seqtk telo'"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="seqtk telo"
TOOL_NAME=seqtk
TOOL_DOCS=https://github.com/lh3/seqtk
VERSION_COMMAND="seqtk 2>&1 | grep -i version"

# Defaults - generic
env_type=container                  # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/seqtk:r93--079a434f17ef2d78
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
motif=CCCTAA                        # -m: canonical vertebrate telomere unit (= TTAGGG / AACCCT)
penalty=1                           # -p: score subtracted per non-motif base
max_drop=2000                       # -d: stop scanning after the score falls this far below its max
min_score=300                       # -s: min. score to report an end as telomeric

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

  'seqtk telo' scans inward from each sequence terminus, adding 1 per base that
  continues a rotation of --motif and subtracting --penalty per base that does
  not, and stops once the score has fallen --max_drop below its running maximum.
  An end is reported, with the array coordinates, when the maximum reaches
  --min_score. This is the same scoring model as hifiasm's '--telo-m' read gate
  and is what Verkko uses to place telomeres, so it keeps the assessment
  consistent with the assembler.

  Because the scan starts at the terminus itself, an array that sits even a few
  kb inside the contig cannot be reached - the score has already dropped out.
  That is the deliberate difference from the VGP telomere pipeline
  (find_telomere; github.com/VGP/vgp-assembly), which counts a telomeric block
  anywhere within 50 kb of the end. Run this one as the strict
  second opinion: contigs it calls are capped at the terminus, full stop.

  Unlike a per-window repeat count, the reported interval IS the array, so the
  output doubles as a measurement of telomere length.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i data/assembly.fasta -o results/seqtk-telo
  - With hifiasm's own threshold:
      sbatch $0 -i results/asm.fasta -o results/seqtk-telo --min_score 500

REQUIRED OPTIONS:
  -i/--infile         <file>  Input genome FASTA file
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --motif             <str>   Telomeric repeat unit to search for             [default: $motif]
  --penalty           <int>   Score subtracted per non-motif base             [default: $penalty]
  --max_drop          <int>   Stop after the score drops this far below its    [default: $max_drop]
                              running maximum
  --min_score         <int>   Min. score to report an end as telomeric        [default: $min_score]
  --prefix            <str>   Output file prefix                              [default: input file basename]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<prefix>.telo.bed              - one line per telomeric end:
                                            contig, array start, array end, contig length
  <outdir>/<prefix>.telo.count            - total telomeric bp and total input bp
  <outdir>/<prefix>.telomere-summary.tsv  - per contig: length, array length at
                                            each end, and 'both' / 'start' /
                                            'end' / 'none'

  Alongside the tool's own output, '<outdir>/logs' will contain:
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

SOFTWARE DOCUMENTATION:
  - $TOOL_DOCS
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
version_only=false
infile=
outdir=
prefix=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --prefix )          check_val "$1" "${2:-}"; shift; prefix=$1 ;;
        --motif )           check_val "$1" "${2:-}"; shift; motif=$1 ;;
        --penalty )         check_val "$1" "${2:-}"; shift; penalty=$1 ;;
        --max_drop )        check_val "$1" "${2:-}"; shift; max_drop=$1 ;;
        --min_score )       check_val "$1" "${2:-}"; shift; min_score=$1 ;;
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

# Print version info and exit, if requested
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! "$motif" =~ ^[ACGTacgt]+$ ]] && die "--motif must be a DNA string, not '$motif'"
[[ ! "$min_score" =~ ^[0-9]+$ ]] && die "--min_score must be a non-negative integer, not '$min_score'"
[[ ! "$max_drop" =~ ^[0-9]+$ ]] && die "--max_drop must be a non-negative integer, not '$max_drop'"

# Infer the prefix from the input file if it was not given
[[ -z "$prefix" ]] && prefix=$(basename "$infile" | sed -E 's/\.(fa|fasta|fna)(\.gz)?$//')

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

mkdir -p "$outdir"
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

# Define outputs
telo_bed="$outdir"/"$prefix".telo.bed
telo_count="$outdir"/"$prefix".telo.count
lens_tsv="$outdir"/"$prefix".lens
summary_tsv="$outdir"/"$prefix".telomere-summary.tsv

# Record how this script was called
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
echo "Output prefix:                            $prefix"
echo "Telomeric motif:                          $motif"
echo "Penalty per non-motif base:               $penalty"
echo "Max. score drop before stopping:          $max_drop"
echo "Min. score to call an end telomeric:      $min_score"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# seqtk writes its two summary counts to stderr, and so does runstats, so the
# combined stream is split again afterwards: seqtk reports first, runstats only
# once the command has exited
log_time "Running $TOOL_NAME telo..."
tmp_err=$(mktemp "$LOG_DIR"/seqtk-telo-stderr.XXXXXX)
eval runstats "$TOOL_BINARY" \
    -m "$motif" \
    -p "$penalty" \
    -d "$max_drop" \
    -s "$min_score" \
    $more_opts \
    "$(printf '%q' "$infile")" \
    > "$telo_bed" 2> "$tmp_err"
awk 'NR == 1' "$tmp_err" > "$telo_count"
awk 'NR > 1' "$tmp_err"
rm -f "$tmp_err"

log_time "Total telomeric bp and total input bp:"
cat "$telo_count"

# 'seqtk telo' only emits the ends it calls, so the lengths of the rest come
# from 'seqtk comp'
log_time "Recording the sequence lengths..."
eval "${TOOL_BINARY% *}" comp "$(printf '%q' "$infile")" | cut -f 1,2 > "$lens_tsv"
[[ ! -s "$lens_tsv" ]] && die "seqtk comp did not write $lens_tsv - check the log above"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
# Per contig: the array length at each end and whether each end is telomeric.
# The call is seqtk's own - a contig end appears here only if seqtk reported it.
# In seqtk's BED, a 5p array starts at 0 and a 3p array ends at the contig length.
log_time "Summarising the telomeric ends per contig..."
awk -v OFS='\t' -v bed="$telo_bed" '
    FNR == NR { len[$1] = $2; order[++n] = $1; next }        # the .lens file

    FILENAME == bed {
        if ($2 == 0) bp5[$1] = $3 - $2; else bp3[$1] = $3 - $2
    }

    END {
        print "contig", "length", "telo_5p_bp", "telo_3p_bp", "status"
        for (i = 1; i <= n; i++) {
            c = order[i]
            status = (c in bp5) ? ((c in bp3) ? "both" : "start") : ((c in bp3) ? "end" : "none")
            print c, len[c], bp5[c] + 0, bp3[c] + 0, status
        }
    }
' "$lens_tsv" "$telo_bed" > "$summary_tsv"

log_time "Contigs per telomere status:"
awk -F'\t' 'NR > 1 { n[$5]++ } END { for (s in n) printf "  %-6s %d\n", s, n[s] }' "$summary_tsv"

log_time "Contigs telomeric at both ends (telomere-to-telomere):"
awk -F'\t' 'NR > 1 && $5 == "both" { print "  " $1 }' "$summary_tsv"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
