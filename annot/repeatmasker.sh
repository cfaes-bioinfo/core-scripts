#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=repeatmasker
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run RepeatMasker on a genome assembly to identify and mask repetitive elements."
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=RepeatMasker
TOOL_NAME=RepeatMasker
TOOL_DOCS=https://www.repeatmasker.org/
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=container          # 'conda' / 'container' / 'none'
container_url=oras://community.wave.seqera.io/library/repeatmasker:4.2.3--bf81e1c6f13e0d00
container_dir="$HOME/containers" # Where to download a container to (if needed)
container_path=             # Full path to a pre-downloaded container image
conda_path=

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
      sbatch $0 -i results/genome.fa -o results/repeatmasker --genome_lib results/repeatmodeler/GCA_009761285.1-families.fa
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i results/genome.fa -o results/repeatmasker --species oomycetes --more_opts \"-s\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTA file (genome assembly)
  -o/--outdir         <dir>   Output dir (will be created if needed)

ONE OF THESE TWO OPTIONS IS REQUIRED (THEY ARE MUTUALLY EXCLUSIVE):
  --genome_lib        <file>  Genome repeat library FASTA file produced by RepeatModeler (repeatmodeler.sh script)
  --species           <str>   Species or taxonomic group name
                              To check which species/groups are available, run, e.g:
                              /fs/ess/PAS0471/jelmer/conda/repeatmasker/share/RepeatMasker/famdb.py names 'oomycetes'

OTHER KEY OPTIONS:
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

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
version_only=false  # When true, just print tool & script version info and exit
infile=
outdir=
genome_lib= && genome_lib_opt=
species= && species_opt=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --genome_lib )      check_val "$1" "${2:-}"; shift; genome_lib=$1 ;;
        --species )         check_val "$1" "${2:-}"; shift; species=$1 ;;
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
[[ -z "$species" ]] && [[ -z "$genome_lib" ]] && die "No --species or --genome_lib specified, one of these is required" "$all_opts"
[[ -n "$species" ]] && [[ -n "$genome_lib" ]] && die "Both --species and --genome_lib are specified, but you can only use one of these options" "$all_opts"
[[ -n "$genome_lib" && ! -f "$genome_lib" ]] && die "Input file $genome_lib does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Make file paths absolute, because the script moves into the output dir
infile=$(realpath "$infile")
[[ -n "$genome_lib" ]] && genome_lib=$(realpath "$genome_lib")
outdir=$(realpath -m "$outdir")

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

# Species/genome lib args
[[ -n "$species" ]] && species_opt="-species $(printf '%q' "$species")"
[[ -n "$genome_lib" ]] && genome_lib_opt="-lib $(printf '%q' "$genome_lib")"

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
[[ -n $genome_lib ]] && echo "Genome database from RepeatModeler:       $genome_lib"
[[ -n $species ]] && echo "Species name:                             $species"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ -n $genome_lib ]] && ls -lh "$genome_lib"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# Move into the output dir
cd "$outdir" || die "Can't change to output dir $outdir"

# Run the tool
log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    -pa $(( threads / 4 > 0 ? threads / 4 : 1 )) \
    -dir . \
    -gff \
    -html \
    $genome_lib_opt \
    $species_opt \
    $more_opts \
    "$(printf '%q' "$infile")"

#? -s  Slow search; 0-5% more sensitive, 2-3 times slower than default
#? -q  Quick search; 5-10% less sensitive, 2-5 times faster than default
#? -qq Rush job; about 10% less sensitive, 4->10 times faster than default
#?        (quick searches are fine under most circumstances) repeat options

#? To check available species, e.g:
# /fs/ess/PAS0471/jelmer/conda/repeatmasker-4.1.2.p1/share/RepeatMasker/famdb.py names 'oomycetes'
# /fs/ess/PAS0471/jelmer/conda/repeatmasker-4.1.2.p1/share/RepeatMasker/famdb.py names 'stramenopiles'
# /fs/ess/PAS0471/jelmer/conda/repeatmasker-4.1.2.p1/share/RepeatMasker/famdb.py names 'phytophthora'

#? Download parts of the Dfam database: https://www.dfam.org/releases/current/families/FamDB/

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$outdir"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
