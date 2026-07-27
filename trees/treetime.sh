#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=6
#SBATCH --mem=24G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=treetime
#SBATCH --output=slurm-treetime-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run TreeTime to date a phylogenetic tree using either tip dates or a clock rate"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=treetime
TOOL_NAME=Treetime
TOOL_DOCS=https://treetime.readthedocs.io
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                          # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/treetime:0.12.1--7f0a99752f652586
container_path=
dl_container=false
container_dir="$HOME/containers"

# Defaults - parameters
confidence_opt="--confidence"

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/snippy/core.full.aln -o results/treetime --dates metadata/dates.tsv"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--alignment      <file>  Input alignment file in FASTA, Phylip, or VCF format"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --dates             <file>  Input CSV/TSV with sampling date for each sample"
    echo "                                Should have columns 'node_name' and 'date', with dates as YYYY-MM-DD"
    echo "                                If column names are different, use '--more_opts --date-column <date-column> --name-column <samplename-column>'"
    echo "  --clock_rate        <str>   Clock rate to assume                    [default: no clock rate - estimate rate from tip dates]"
    echo "                                Note: even when specifying a clock rate, you still need a dates file"
    echo "  --tree              <file>  Tree file in Nexus or Newick format"
    echo "                                If no tree file is provided, TreeTime will infer one"
    echo "  --more_opts              <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or --dl_container is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: false]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "HARDCODED TREETIME OPTIONS:"
    echo
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
    echo
}

# Function to source the script with Bash functions
source_function_script() {
    # Determine the location of this script, and based on that, the function script
    if [[ "$IS_SLURM" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script=$(realpath "$script_dir"/../dev/"$(basename "$FUNCTION_SCRIPT_URL")")
    # Download the function script if needed, then source it
    if [[ ! -f "$function_script" ]]; then
        echo "Can't find script with Bash functions ($function_script), downloading from GitHub..."
        function_script=$(basename "$FUNCTION_SCRIPT_URL")
        wget "$FUNCTION_SCRIPT_URL" -O "$function_script"
    fi
    source "$function_script"
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
infile=
outdir=
date_file=
tree= && tree_opt=
clock_rate= && clock_rate_opt=
date_opt=
more_opts=
version_only=false

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --dates )           shift && date_file=$1 ;;
        --tree )            shift && tree=$1 ;;
        --clock_rate )      shift && clock_rate=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input alignment file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$date_file" ]] && die "No date file specified, do so with --date_file" "$all_opts"
[[ ! -f "$infile" ]] && die "Input alignment file $infile does not exist"
[[  -n "$date_file" && ! -f "$date_file" ]] && die "Input file $date_file does not exist"
[[ -n "$tree" && ! -f "$tree" ]] && die "Input tree file $tree does not exist"

# Define outputs and options based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
file_id=$(basename "${infile%.*}")
[[ -n $tree ]] && tree_opt="--tree $tree"
if [[ -n $clock_rate ]]; then
    clock_rate_opt="--clock-rate $clock_rate"
    confidence_opt=                             # Can't use this option with fixed rate
fi
date_opt="--dates $date_file"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Output dir:                               $outdir"
echo "Input alignment file:                     $infile"
echo "CSV/TSV dates input file:                 $date_file"
[[ -n "$tree" ]] && echo "Input tree file:                          $tree"
[[ -n "$clock_rate" ]] && echo "Clock rate:                               $clock_rate"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile" "$date_file"
[[ -n "$tree" ]] && ls -lh "$tree"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --aln "$infile" \
    --outdir "$outdir" \
    $tree_opt \
    $clock_rate_opt \
    $date_opt \
    $confidence_opt \
    --covariation \
    --tip-labels \
    --stochastic-resolve \
    --plot-tree "$file_id".png \
    $more_opts

#? Other TreeTime options:
#> --reroot         min_dev / least-squares / oldest
#> --keep-root

log_time "Showing the contents of the output dates.tsv:"
cat -n "$outdir"/dates.tsv

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
