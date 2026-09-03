#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=diamond
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run DIAMOND to perform fast BLAST-like alignment of proteins"
SCRIPT_VERSION="2026-09-02"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=diamond
TOOL_NAME=Diamond
TOOL_DOCS=https://github.com/bbuchfink/diamond/wiki
VERSION_COMMAND="$TOOL_BINARY version"

# Defaults - generics
env_type=container
container_url=oras://community.wave.seqera.io/library/diamond:2.2.5--95b06d7b3a97178d
container_dir="$HOME/containers"
container_path=
conda_path=

# Defaults - tool parameters
blast_type=blastp                   # Or blastx
out_format="6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qlen qcovhsp slen stitle"
max_target_seqs=25                  # Same as DIAMOND default
evalue="0.001"                      # E-value threshold
pct_id=0                            # % identity threshold (empty => no threshold)
pct_qcov=0                          # Threshold for % of query covered by the alignment length
pct_scov=0                          # Threshold for % of subject covered by the alignment length
add_header=true                     # Add column header to final BLAST output file
sensitivity=sensitive               # Sensitivity

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
  - Basic usage:
      sbatch $0 -i query.fa -o results/diamond --db data/diamond_db.dmnd
  - Translated search of nucleotide queries against a protein db:
      sbatch $0 -i query.fa -o results/diamond --db data/diamond_db.dmnd --blast_type blastx

REQUIRED OPTIONS:
  -i/--infile         <file>  Input (query) FASTA file (can contain one or more sequences)
  -o/--outdir         <dir>   Output dir (will be created if needed)
  --db                <file>  Diamond DB '.dmnd' file (create one with diamond_db.sh)

OTHER KEY OPTIONS:
  --blast_type        <str>   BLAST type: 'blastp' or 'blastx'                  [default: $blast_type]
  --sens              <str>   Sensitivity, one of 'fast', 'mid-sensitive',      [default: $sensitivity]
                              'sensitive', 'more-sensitive', 'very-sensitive',
                              or 'ultra-sensitive'
  --out_format        <str>   Output format string                              [default: see below]
                              NOTE: changing this may break the summary counts,
                              which assume the default column order
                              '$out_format'
  --no_header                 Don't add a header to the output TSV file         [default: add a header]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

THRESHOLD AND FILTERING OPTIONS:
  --max_target_seqs   <int>   Max. nr of target sequences to keep               [default: $max_target_seqs]
  --evalue            <num>   E-value threshold in scientific notation          [default: $evalue]
  --pct_id            <int>   Percentage identity threshold                     [default: $pct_id]
  --pct_qcov          <int>   Threshold for % of the query covered by the alignment    [default: $pct_qcov]
  --pct_scov          <int>   Threshold for % of the subject covered by the alignment  [default: $pct_scov]

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
version_only=false                 # When true, just print tool & script version info and exit
infile=
outdir=
db=
header_opt=
more_opts=
threads=

# Parse command-line args
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --sens )            check_val "$1" "${2:-}"; shift; sensitivity=$1 ;;
        --out_format )      check_val "$1" "${2:-}" lax; shift; out_format=$1 ;;
        --no_header )       add_header=false ;;
        --max_target_seqs ) check_val "$1" "${2:-}"; shift; max_target_seqs=$1 ;;
        --db )              check_val "$1" "${2:-}"; shift; db=$1 ;;
        --blast_type )      check_val "$1" "${2:-}"; shift; blast_type=$1 ;;
        --evalue )          check_val "$1" "${2:-}"; shift; evalue=$1 ;;
        --pct_id )          check_val "$1" "${2:-}"; shift; pct_id=$1 ;;
        --pct_qcov )        check_val "$1" "${2:-}"; shift; pct_qcov=$1 ;;
        --pct_scov )         check_val "$1" "${2:-}"; shift; pct_scov=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )      check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )  check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )    version_only=true ;;
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
[[ -z "$db" ]] && die "No database file specified, do so with --db" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -f "$db" ]] && die "Database file $db does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"
outfile="$outdir"/diamond_out.tsv
[[ "$add_header" == true ]] && header_opt="--header"
n_in=$(grep -c "^>" "$infile" || true)

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
echo "Output file:                              $outfile"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
echo "DIAMOND db:                               $db"
echo
echo "BLAST type:                               $blast_type"
echo "Add column header to output?              $add_header"
echo "Sensitivity:                              $sensitivity"
echo "Evalue threshold:                         $evalue"
[[ -n "$pct_id" ]] && echo "Percent identity threshold:               $pct_id"
[[ -n "$pct_qcov" ]] && echo "Percent query coverage threshold:         $pct_qcov"
[[ -n "$pct_scov" ]] && echo "Percent subject coverage threshold:       $pct_scov"
[[ -n "$max_target_seqs" ]] && echo "Max. nr. of target sequences:             $max_target_seqs"
echo "Number of queries in the input file:      $n_in"
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

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY $blast_type \
    --db "$db" \
    --query "$infile" \
    --out "$outfile" \
    --outfmt $out_format \
    --max-target-seqs "$max_target_seqs" \
    --evalue "$evalue" \
    --id "$pct_id" \
    --query-cover "$pct_qcov" \
    --subject-cover "$pct_scov" \
    --"$sensitivity" \
    --threads "$threads" \
    $header_opt \
    $more_opts

# ==============================================================================
#                           REPORT & WRAP UP
# ==============================================================================
# Report some basic stats on the output
# NOTE: DIAMOND's '--header' lines all start with '#', so they are skipped here
n_hits=$(grep -vc "^#" "$outfile" || true)
n_queries=$( { grep -v "^#" "$outfile" || true; } | cut -f 1 | sort -u | wc -l)
n_subjects=$( { grep -v "^#" "$outfile" || true; } | cut -f 2 | sort -u | wc -l)

log_time "Done. Summary of hits:"
echo "Number of queries in the input file:                  $n_in"
echo "Total number of hits in the final output file:        $n_hits"
echo "Number of distinct queries in the final output file:  $n_queries"
echo "Number of distinct subjects in the final output file: $n_subjects"

# Final logging
log_time "Listing the output file:"
ls -lh "$outfile"
final_reporting
