#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=8:00:00
#SBATCH --cpus-per-task=12
#SBATCH --mem=50G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=iqtree
#SBATCH --output=slurm-iqtree-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Construct a phylogenetic tree from a FASTA alignment using IQ-tree"
SCRIPT_VERSION="2025-10-22"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=iqtree
TOOL_NAME=IQ-TREE
TOOL_DOCS=https://iqtree.org/doc
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda
conda_path=/fs/ess/PAS0471/conda/iqtree_3.0.1
container_dir="$HOME/containers"
container_url=oras://community.wave.seqera.io/library/iqtree:3.0.1--340858492bd2bcb9
container_path=

# Defaults - tool parameters
auto_cores=false                    # Don't use IQ-tree's 'AUTO' core mode
nboot= && boot_opt=                 # No bootstrapping by default
model= && model_opt=                # Use IQ-tree's default model (MFP => Pick model)
modelset= && modelset_opt=          # Restrict ModelFinder model search to a set of models
fast=false && fast_opt=             # Run IQ-Tree with "--fast" option
root= && root_opt=                  # Pre-specified root/outgroup

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
  - Basic usage -- include 1000 ultrafast-bootstraps:
    sbatch $0 -i results/COI_aligned.fa -o results/iqtree --nboot 1000
  - Also perform dating on the tree (see http://www.iqtree.org/doc/Dating):
    sbatch $0 -i aln.fa -o results/iqtree --more_opts '--date metadata/dates.tsv --date-ci 100'
  - Date a previously inferred tree (see http://www.iqtree.org/doc/Dating):
    sbatch $0 -i aln.fa -o results/iqtree --model HKY --more_opts '--date metadata/dates.tsv --date-ci 100 -te results/iqtree/tree.treefile'

REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTA file (alignment)
                              Should contain multiple, aligned sequences
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --out_prefix        <str>   Output file prefix                                [default: basename of input file]
  --root              <str>   Specify outgroup/root sample ID                   [default: none]
  --fast                      Run IQ-Tree in fast mode                          [default: $fast]
  --model             <str>   Mutation model                                    [default: IQ-tree's default = MFP => Pick model]
  --modelset          <str>   Restrict ModelFinder search to a set of models    [default: off]
  --nboot             <int>   Nr of ultrafast bootstraps                        [default: no bootstrapping]
  --auto_cores                Use IQ-tree's 'AUTO' core mode                    [default: use nr of cores for batch job]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME
    
UTILITY OPTIONS:
  --env_type          <str>   Use a Singularity container ('container')         [default: $env_type]
                              or a Conda environment ('conda') 
  --conda_path        <dir>   Full path to a Conda environment to use           [default: $conda_path]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_url     <str>   URL to download a container from                  [default (if any): $container_url]
  --container_path    <file>  Local singularity image file (.sif) to use        [default (if any): $container_path]
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
        --out_prefix )      shift && out_prefix=$1 ;;
        --modelset )        shift && modelset=$1 ;;
        --model )           shift && model=$1 ;;
        --nboot )           shift && nboot=$1 ;;
        --root )            shift && root=$1 ;;
        --auto_cores )      auto_cores=true ;;
        --fast )            fast=true && fast_opt="-fast" ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --conda_path )      shift && conda_path=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
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
set_threads "$IS_SLURM"
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
mem_gb=$((8*(SLURM_MEM_PER_NODE / 1000)/10))G   # 80% of available memory in GB
[[ "$auto_cores" == true ]] && threads="AUTO"
[[ -n "$nboot" ]] && boot_opt="--ufboot $nboot"
[[ -n "$model" ]] && model_opt="-m $model"
[[ -n "$modelset" ]] && modelset_opt="-mset $modelset"
[[ -z "$out_prefix" ]] && out_prefix=$(basename "${infile%.*}")
[[ -n "$root" ]] && root_opt="-o $root"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input FASTA file:                         $infile"
echo "Output dir:                               $outdir"
echo "Output file prefix:                       $out_prefix"
echo "Run IQ-Tree in fast mode:                 $fast"
echo "Use IQ-Tree's 'AUTO' core mode:           $auto_cores"
echo "Number of threads to use:                 $threads"
[[ -n "$modelset" ]] && echo "Model set for MFP:                        $modelset"
[[ -n "$model" ]] && echo "Model:                                    $model"
[[ -n "$nboot" ]] && echo "Number of ultrafast bootstraps:           $nboot"
[[ -n "$root" ]] && echo "Root/outgroup:                            $root"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -s "$infile" \
    --prefix "$outdir"/"$out_prefix" \
    $model_opt \
    $modelset_opt \
    $fast_opt \
    $boot_opt \
    $root_opt \
    -nt "$threads" \
    -ntmax "$threads" \
    -mem "$mem_gb" \
    -redo \
    $more_opts

#? Options used:
#> -m MFP       => Model selection with ModelFinder (is the IQ-tree default, too)
#> -redo        => Will overwrite old results

#? Consider these options, too:
#> -alrt 1000 --wbtl -alninfo

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
