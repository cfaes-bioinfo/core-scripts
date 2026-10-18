#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=32
#SBATCH --mem=120G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=eggnogmap
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Functionally annotate a proteome with eggNOG-mapper v3 (eggNOG 7): GO terms, KEGG, COG categories, PFAM domains and preferred gene names"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=emapper.py
TOOL_NAME=eggNOG-mapper
TOOL_DOCS="https://github.com/eggnogdb/eggnog-mapper/wiki"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
# NOTE: v3.0.0-beta6 has no Bioconda or PyPI package - it was pip-installed from
# a git checkout (tag v3.0.0-beta6) into the Conda env below.
env_type=conda
conda_path=/fs/ess/PAS0471/conda/eggnog-mapper_3.0.0b6
container_url=
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
db_dir=/fs/ess/PAS0471/refdata/eggnog/eggnog7   # eggNOG 7 DB, from download/dl-eggnog3.sh
itype=proteins
sensmode=more-sensitive     # Ceiling for DIAMOND's iterated search (see below)
report_dropped=true         # Log why a query got no annotation - QC, costs nothing

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

  eggNOG-mapper places each protein in an orthologous group and transfers the
  annotation that the group's members agree on: GO terms, KEGG, COG categories,
  PFAM domains and gene symbols ('Preferred_name').

  WHY v3 (see annot/eggnogmap.sh for the stable 2.1.x version):
  the newest database the 2.1.x line can read is emapperdb-5.0.2 (eggNOG 5.0,
  built March 2021), and no newer one exists on that server. Current orthology
  data is only reachable through v3, which is still a pre-release.

  NOTE ON --sensmode: with DIAMOND's iterated search (emapper's default), this
  is a *ceiling*, not a fixed setting. Every query starts at the fastest mode
  and only the ones that came back unaligned are re-searched at higher
  sensitivity, so raising the ceiling costs time only on divergent queries.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 \\
          -i results/gffread/genome.protein.faa \\
          -o results/eggnog --prefix genome

REQUIRED OPTIONS:
  -i/--infile         <file>  Input protein FASTA
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --db_dir            <dir>   Dir with the eggNOG 7 database                    [default: $db_dir]
  --prefix            <str>   Basename for the output files                     [default: basename of --infile, minus extension]
  --itype             <str>   Input type: 'proteins', 'CDS', 'genome', 'metagenome' [default: $itype]
  --sensmode          <str>   DIAMOND sensitivity ceiling: 'default',           [default: $sensmode]
                              'fast', 'mid-sensitive', 'sensitive',
                              'more-sensitive', 'very-sensitive', 'ultra-sensitive'
  --no_report_dropped         Don't write the '.emapper.dropped' QC log         [default: write it]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  <outdir>/<prefix>.emapper.annotations     - the annotation table (one row per annotated query)
  <outdir>/<prefix>.emapper.seed_orthologs  - the DIAMOND seed-ortholog hits
  <outdir>/<prefix>.emapper.hits            - all DIAMOND hits per query
  <outdir>/<prefix>.emapper.dropped         - queries that got no annotation, with the reason

  Alongside those, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment
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
prefix=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )      check_val "$1" "${2:-}"; shift; infile=$1 ;;
        --db_dir )           check_val "$1" "${2:-}"; shift; db_dir=$1 ;;
        -o | --outdir )      check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --prefix )           check_val "$1" "${2:-}"; shift; prefix=$1 ;;
        --itype )            check_val "$1" "${2:-}"; shift; itype=$1 ;;
        --sensmode )         check_val "$1" "${2:-}"; shift; sensmode=$1 ;;
        --no_report_dropped ) report_dropped=false ;;
        --more_opts )        check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )         check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )       check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )    check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )    check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )   check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )        script_help; exit 0 ;;
        -v | --version)      version_only=true ;;
        * )                  die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check software env
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"

# Load the software environment
load_env   # Note: reads the env_type/conda_path/container_* globals, takes no args
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$db_dir" ]] && die "No database dir specified, do so with --db_dir" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -d "$db_dir" ]] && die "Database dir $db_dir does not exist"
# A truncated eggnog.db is the failure mode that costs a whole job, so check up front
for db_file in eggnog.db eggnog_proteins.dmnd; do
    [[ ! -s "$db_dir"/"$db_file" ]] &&
        die "Database dir $db_dir has no $db_file - rerun download/dl-eggnog3.sh"
done

# emapper.py --version prints its version and exits before it processes --data_dir,
# so it looks for the DB in its install dir and always reports 'DB version: unknown'.
# Call the same function it uses, after pointing it at the actual DB dir.
VERSION_COMMAND="python -c 'from eggnogmapper.common import set_data_path, get_full_version_info; set_data_path(\"$db_dir\"); print(get_full_version_info())'"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
[[ -z "$prefix" ]] && prefix=$(basename "${infile%.*}")
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
annot_file="$outdir"/"$prefix".emapper.annotations

# emapper checks that --output_dir and --temp_dir exist before it starts
temp_dir=${TMPDIR:-$outdir/tmp}
mkdir -p "$temp_dir"

# Build the option string
dropped_opt=
[[ "$report_dropped" == true ]] && dropped_opt="--report_dropped"

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
echo "Input protein FASTA:                      $infile"
echo "eggNOG database dir:                      $db_dir"
echo "Output dir:                               $outdir"
echo "Output prefix:                            $prefix"
echo "Input type:                               $itype"
echo "DIAMOND sensitivity ceiling:              $sensmode"
echo "Write the 'dropped' QC log:               $report_dropped"
echo "Temporary dir:                            $temp_dir"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME: $more_opts"
echo
echo "Number of sequences in the input file:    $(grep -c '^>' "$infile" || true)"
log_time "Listing the input file:"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
# '--tax_scope' is left at the tool default (auto_narrow: a per-seed ceiling,
# Eukaryota for eukaryotic seeds), which suits a eukaryotic proteome
eval runstats "$TOOL_BINARY" \
    -i "$infile" \
    --itype "$itype" \
    --data_dir "$db_dir" \
    --output "$prefix" \
    --output_dir "$outdir" \
    --temp_dir "$temp_dir" \
    --dmnd_sensmode "$sensmode" \
    --cpu "$threads" \
    --override \
    $dropped_opt \
    $more_opts

[[ ! -s "$annot_file" ]] && die "No annotation file was written to $annot_file"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Summarizing the annotations..."
# Column positions differ between emapper versions, so find each field by its
# header name. The header line is the last comment line before the data.
n_in=$(grep -c '^>' "$infile" || true)
awk -F'\t' -v n_in="$n_in" '
    /^#query/ { for (i = 1; i <= NF; i++) { h = $i; sub(/^#/, "", h); col[h] = i }; next }
    /^#/ { next }
    { n_annot++
      if (col["Preferred_name"] && $col["Preferred_name"] != "-") n_name++
      if (col["GOs"] && $col["GOs"] != "-") n_go++
      if (col["KEGG_ko"] && $col["KEGG_ko"] != "-") n_ko++
      if (col["PFAMs"] && $col["PFAMs"] != "-") n_pfam++
    }
    END {
      if (n_in == 0) { print "  WARNING: no sequences found in the input file"; exit }
      printf "  Queries in the input file:              %8d\n", n_in
      printf "  Queries with any annotation:            %8d (%.1f%%)\n", n_annot, 100 * n_annot / n_in
      printf "  ... with a preferred gene name:         %8d (%.1f%%)\n", n_name, 100 * n_name / n_in
      printf "  ... with >= 1 GO term:                  %8d (%.1f%%)\n", n_go, 100 * n_go / n_in
      printf "  ... with >= 1 KEGG KO:                  %8d (%.1f%%)\n", n_ko, 100 * n_ko / n_in
      printf "  ... with >= 1 PFAM domain:              %8d (%.1f%%)\n", n_pfam, 100 * n_pfam / n_in
    }' "$annot_file"

if [[ "$report_dropped" == true && -s "$outdir"/"$prefix".emapper.dropped ]]; then
    log_time "Reasons queries were dropped:"
    awk -F'\t' '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "reason") col = i; next }
        { n[col ? $col : $NF]++ }
        END { for (r in n) printf "  %-32s %8d\n", r, n[r] }' \
        "$outdir"/"$prefix".emapper.dropped | sort -k2,2nr
fi

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
