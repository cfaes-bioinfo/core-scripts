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
SCRIPT_VERSION="2026-08-25"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=diamond
TOOL_NAME=Diamond
TOOL_DOCS=https://github.com/bbuchfink/diamond/wiki
VERSION_COMMAND="$TOOL_BINARY version"

# Defaults - generics
env_type=container                       # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/diamond
container_url=oras://community.wave.seqera.io/library/diamond:2.1.11--8bbb53f9a405f963
container_path=
container_dir="$HOME/containers"

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
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i query.fa -o results/diamond --db data/diamond_db.dmnd"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input FASTA file (can contain one or more sequences)"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  --db                <str>   Diamond DB '.dmnd' file (can create this with diamond_db.sh)"
    echo
    echo "GENERAL OPTIONS (OPTIONAL):"
    echo "  --blast_type        <str>   BLAST type: 'blastp' or 'blastx'        [default: $blast_type]"
    echo "  --sens              <str>   Sensitivity: one of 'fast', 'mid-sensitive', 'sensitive', 'more-sensitive', 'very-sensitive', 'ultra-sensitive'"
    echo "                                                                      [default: $sensitivity]"
    echo "  --out_format        <str>   Output format string. NOTE: changing this may mess up output filtering steps, which rely on the default format"
    echo "                                                                      [default: $out_format]"
    echo "  --no_header                 Don't add column headers to final output TSV file [default: add]"
    echo "                                The header won't be added to the raw output file, which can be used for filtering"
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "THRESHOLD AND FILTERING OPTIONS (OPTIONAL):"
    echo "  --max_target_seqs   <int>   Max. nr of target sequences to keep                     [default: DIAMOND default (=25)]"
    echo "  --evalue            <num>   E-value threshold in scientific notation                [default: $evalue]"
    echo "  --pct_id            <int>   Percentage identity threshold                           [default: $pct_id]"
    echo "  --pct_qcov          <int>   Threshold for % of query covered by the alignment       [default: $pct_qcov]"
    echo "  --pct_scov          <int>   Threshold for % of query covered by the alignment       [default: $pct_scov]"
    echo
    echo "OUTPUT:
  Alongside the tool's own output, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:"
    echo "  --env_type          <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v/--version                Print the version of this script and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
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
        --pct_qcov )         check_val "$1" "${2:-}"; shift; pct_qcov=$1 ;;
        --pct_scov )         check_val "$1" "${2:-}"; shift; pct_scov=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
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
n_in=$(grep -c "^>" "$infile")

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input file:                               $infile"
echo "Output dir:                               $outdir"
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
if [[ "$add_header" == false ]]; then
    n_hits=$(wc -l < "$outfile")
    n_queries=$(cut -f 1 "$outfile" | sort -u | wc -l)
    n_subjects=$(cut -f 2 "$outfile" | sort -u | wc -l)
else
    n_hits=$(tail -n+4 "$outfile" | wc -l)
    n_queries=$(tail -n+4 "$outfile" | sort -u | wc -l)
    n_subjects=$(tail -n+4 "$outfile" | cut -f 2 | sort -u | wc -l)
fi

#
log_time "Done. Summary of hits:"
echo "Number of queries in the input file:                  $n_in"
echo "Total number of hits in the final output file:        $n_hits"
echo "Number of distinct queries in the final output file:  $n_queries"
echo "Number of distinct subjects in the final output file: $n_subjects"

# Final logging
log_time "Listing the output file:"
ls -lh "$outfile"
final_reporting
