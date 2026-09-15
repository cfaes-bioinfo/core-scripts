#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=12
#SBATCH --mem=50G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=clonalframeml
#SBATCH --output=slurm-clonalframeml-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run ClonalFrameML to infer recombination (HGT) in bacterial genomes,
and run maskrc-svg to mask recombinant regions"
SCRIPT_VERSION="2025-10-20"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=ClonalFrameML
TOOL_NAME=ClonalFrameML
TOOL_DOCS=https://github.com/xavierdidelot/ClonalFrameML
VERSION_COMMAND="$TOOL_BINARY | head -n 1"

# Defaults - generics
env_type=conda                  # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/clonalframeml
container_url=
container_dir="$HOME/containers"
container_path=/fs/ess/PAS0471/containers/keep/maskrc-svg_for-clonalframeml.img

# Defaults - parameters
tree_tool=iqtree            #! NOTE: ClonalFrameML may not accept FastTree trees?! Have had problems with this at least
force_tree=false            # If tree is found, don't rerun tree-building

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
      sbatch $0 -i results/roary/core_gene_alignment.aln -o results/clonalframeml
    
REQUIRED OPTIONS:
  -i/--infile         <file>  Input alignment file from Roary/Panaroo or similar
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --out_prefix        <str>   Output file prefix                                [default: basename of input file]
  --tree_tool         <str>   Tool to build initial tree: 'iqtree' or 'fasttree'[default: 'iqtree']
  --force_tree                Even if initial tree file is found, rebuild it    [default: use existing tree]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME
    
UTILITY OPTIONS:
  --container_path    <file>  Local container image file ('.sif') to use        [default: $container_path]
                              with maskrc-svg
  --conda_path        <dir>   Full path to a Conda environment to use           [default: $conda_path]
                              with IQ-Tree and ClonalFrameML
  -h/--help                   Print this help message
  -v/--version                Print script and $TOOL_NAME versions
    
TOOL DOCUMENTATION:
  - ClonalFrameML: $TOOL_DOCS
  - maskrc-svg: https://github.com/kwongj/maskrc-svg
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
infile=
outdir=
out_prefix=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --tree_tool )       shift && tree_tool=$1 ;;
        --out_prefix )      shift && out_prefix=$1 ;;
        --force_tree )      force_tree=true ;;
        --more_opts )       shift && more_opts=$1 ;;
        --conda_path )      shift && conda_path=$1 ;;
        --container_path )  shift && container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
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
load_env "$env_type" "$conda_path" "$container_dir" "$container_path" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
mem_gb=4G && [[ "$IS_SLURM" == true ]] && mem_gb=$((8*(SLURM_MEM_PER_NODE / 1000)/10))G
[[ -z "$out_prefix" ]] && out_prefix=$(basename "${infile%.*}")

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
echo "Output file prefix:                       $out_prefix"
echo "Tool to build initial tree:               $tree_tool"
echo "Force tree-building even if file exists:  $force_tree"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Step 1: Create starting tree
if [[ ! -f "$outdir"/"$out_prefix".treefile || "$force_tree" == true ]]; then
    log_time "Running $tree_tool to get a starting tree for ClonalFrameML..."
    
    if [[ "$tree_tool" == "iqtree" ]]; then
        runstats iqtree \
            -s "$infile" --prefix "$outdir"/"$out_prefix" \
            -m MFP -fast -redo -nt "$threads" -ntmax "$threads" -mem "$mem_gb"
    elif [[ "$tree_tool" == "fasttree" ]]; then
        runstats fasttree -nt -gtr < "$infile" > "$outdir"/"$out_prefix".treefile
    fi
else
    log_time "Tree file $outdir/$out_prefix.treefile exists, skipping tree-building..."
fi
log_time "Tree file:"
ls -lh "$outdir"/"$out_prefix".treefile

# Step 2: Run ClonalFrameML
if [[ ! -s "$outdir"/"$out_prefix".labelled_tree.newick ]]; then
    log_time "Running ClonalFrameML..."
    runstats $TOOL_BINARY \
        "$outdir"/"$out_prefix".treefile \
        "$infile" \
        "$outdir"/"$out_prefix" \
        $more_opts
else
    log_time "ClonalFrameML output file $outdir/$out_prefix.labelled_tree.newick exists, skipping ClonalFrameML..."
fi

# Step 3:Run maskrc-svg.py to HGT-mask the alignment
#  (Have to run maskrc-svg.py using a container because the Conda env doesn't work)
log_time "Running maskrc-svg.py..."
runstats apptainer exec "$container_path" \
    maskrc-svg.py \
    --aln "$infile" \
    --symbol '-' \
    --out "$outdir"/"$out_prefix".masked.aln \
    "$outdir"/"$out_prefix"

#? --symbol CHAR        symbol to use for masking (default="?")
#? The positional argument is the prefix used for ClonalFrameML (or Gubbins) output files

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
