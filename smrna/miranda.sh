#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=miranda
#SBATCH --output=slurm-miranda-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Miranda for miRNA target prediction"
SCRIPT_VERSION="2026-04-13"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=miranda
TOOL_NAME=Miranda
TOOL_DOCS=http://www.microrna.org/microrna/getDownloads.do
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url="oras://community.wave.seqera.io/library/miranda:3.3a--e4b92f5b9bbf6eb1"
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters
DEFAULT_SC=140
DEFAULT_EN=-20

# Defaults - tool parameters
sc=$DEFAULT_SC
en=$DEFAULT_EN
strict=true

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
      sbatch $0 -m mirnas.fa -u utr_sequences.fa -o results/miranda
    
REQUIRED OPTIONS:
  -m/--mirna_file     <file>  Input miRNA sequences (FASTA format)
  -u/--utr_file       <file>  Input 3' UTR sequences (FASTA format)
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --sc                <int>   Score threshold                                   [default: $DEFAULT_SC]
  --en                <int>   Energy threshold                                  [default: $DEFAULT_EN]
  --strict                    Use strict seed model (no mismatches/wobbles)     [default: $strict]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME
    
UTILITY OPTIONS:
  --env_type          <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                              ('container') or a Conda environment ('conda') 
  --container_url     <str>   URL to download a container from                  [default: $container_url]
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
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false  # When true, just print tool & script version info and exit
mirna_file=
utr_file=
outdir=
more_opts=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -m | --mirna_file )   shift && mirna_file=$1 ;;
        -u | --utr_file )     shift && utr_file=$1 ;;
        -o | --outdir )       shift && outdir=$1 ;;
        --sc )                shift && sc=$1 ;;
        --en )                shift && en=$1 ;;
        --strict )            strict=true ;;
        --more_opts )         shift && more_opts=$1 ;;
        --env_type )          shift && env_type=$1 ;;
        --conda_path )        shift && conda_path=$1 ;;
        --container_dir )     shift && container_dir=$1 ;;
        --container_url )     shift && container_url=$1 ;;
        --container_path )    shift && container_path=$1 ;;
        -h | --help )         script_help; exit 0 ;;
        -v | --version)       version_only=true ;;
        * )                   die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$env_type" "$conda_path" "$container_dir" "$container_path" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$mirna_file" ]] && die "No miRNA file specified, do so with -m/--mirna_file" "$all_opts"
[[ -z "$utr_file" ]] && die "No UTR file specified, do so with -u/--utr_file" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$mirna_file" ]] && die "miRNA file $mirna_file does not exist"
[[ ! -f "$utr_file" ]] && die "UTR file $utr_file does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
out_raw="$outdir"/miranda_results.txt
out_parsed="$outdir"/miranda_parsed.tsv
mkdir -p "$LOG_DIR" "$outdir"

# Build Miranda command options
miranda_opts="-sc $sc -en $en"
[[ "$strict" == true ]] && miranda_opts="$miranda_opts -strict"
[[ -n "$more_opts" ]] && miranda_opts="$miranda_opts $more_opts"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "miRNA file:                               $mirna_file"
echo "UTR file:                                 $utr_file"
echo "Output dir:                               $outdir"
echo "Score threshold (--sc):                   $sc"
echo "Energy threshold (--en):                  $en"
echo "Strict mode:                              $strict"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
echo "Miranda command options:                  $miranda_opts"
echo "Raw output file:                          $out_raw"
echo "Parsed output file:                       $out_parsed"
log_time "Listing the input file(s):"
ls -lh "$mirna_file" "$utr_file"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Run Miranda
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    "$mirna_file" \
    "$utr_file" \
    $miranda_opts \
    -out "$out_raw"

# Post-process the raw Miranda output into a more usable format (tab-delimited with header)
# Create the header row and append the parsed data into a final file
log_time "Parsing $TOOL_NAME output into a TSV file with per-transcript results..."
echo -e "miRNA\tTarget\tTot_Score\tTot_Energy\tMax_Score\tMax_Energy\tStrand\tLen_miRNA\tLen_Target\tPositions" \
    > "$out_parsed"
grep ">>" "$out_raw" | sed 's/>>//g' >> "$out_parsed"

echo "# Showing the first few lines of the parsed output file:"
head -n 5 "$out_parsed"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lh "$out_raw" "$out_parsed"
final_reporting "$LOG_DIR"