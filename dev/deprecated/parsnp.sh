#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=parsnp
#SBATCH --output=slurm-parsnp-%j.out

#TODO - Can also do recombination filtration

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Parsnp to align bacterial genomes and create a VCF and phylogenetic tree"
SCRIPT_VERSION="2023-08-23"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=parsnp
TOOL_NAME=Parsnp
TOOL_DOCS=https://harvest.readthedocs.io/en/latest/content/parsnp
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                      # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/parsnp
container_path=
container_url=https://depot.galaxyproject.org/singularity/parsnp:1.7.4--hd03093a_1
dl_container=false
container_dir="$HOME/containers"
strict_bash=true
version_only=false                 # When true, just print tool & script version info and exit

# Defaults - tool parameters
use_fasttree=false && tree_opt=
keep_all=false && curated_opt="--curated" # Keep all genomes, i.e. use the --curated flag of Parsnp? Or remove too-divergent genomes?

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
    echo "      sbatch $0 -i results/spades -r data/ref/ref_assmbly.fna -o results/parsnp"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <dir>   Dir with FASTA files to align"
    echo "                                This dir may contain the ref FASTA: it will be excluded by the script"
    echo "  -r/--ref            <file>  Reference genome FASTA file"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --keep_all                  Keep all genomes [default: allow Parsnp to remove too-divergent genomes]"
    echo "  --use_fasttree              Use Fasttree instead of RaxML to build the tree [default: $use_fasttree]"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "                                (NOTE: If no default '--container_url' is listed below,"
    echo "                                 you'll have to provide one in order to run the script with a container.)"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or '--dl_container' is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  --no_strict                 Don't use strict Bash settings ('set -euo pipefail') -- can be useful for troubleshooting"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
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
indir=
ref=
outdir=
opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -r | --ref )        shift && ref=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --use_fasttree )    use_fasttree=false && tree_opt="--use-fasttree" ;;
        --keep_all )        keep_all=true && curated_opt= ;;
        --no_strict )       strict_bash=false ;;
        --env_type )             shift && env_type=$1 ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
        --opts )            shift && opts=$1 ;;
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
[[ "$strict_bash" == true ]] && set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$indir" ]] && die "No input dir specified, do so with -i/--indir" "$all_opts"
[[ -z "$ref" ]] && die "No reference genome FASTA specified, do so with -r/--ref" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$ref" ]] && die "Input file $ref does not exist"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
mapfile -t genomes < <(find "$indir" -iname '*.fasta' -or -iname '*.fa' -or -iname '*.fna' | grep -v "$ref")

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Reference genome FASTA:                   $ref"
echo "Input dir with genomes:                   $indir"
echo "Number of input genomes:                  ${#genomes[@]}"
echo "Output dir:                               $outdir"
echo "Use Fasttree (instead of RaxML):          $use_fasttree"
echo "Keep all genomes?                         $keep_all" 
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the reference FASTA file:"
ls -lh "$ref"
log_time "Listing the genomes:"
ls -lh "${genomes[@]}"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Run Parsnp
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --output-dir "$outdir" \
    --reference "$ref" \
    --vcf${curated_opt} \
    $tree_opt \
    --threads "$threads" \
    --verbose \
    $opts \
    --sequences "${genomes[@]}"

#? --curated will make the program use all provided genomes - otherwise it will exclude divergent ones

# Create a multi-FASTA alignment file (https://harvest.readthedocs.io/en/latest/content/harvest/quickstart.html)
log_time "Running Harvesttool to convert to a FASTA alignment file..."
runstats harvesttools \
    -i "$outdir"/parsnp.ggr -M "$outdir"/parsnp.aln

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
