#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=25
#SBATCH --mem=100G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=merge_bam
#SBATCH --output=slurm-merge_bam-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Merge BAM files and sort the output BAM file"
SCRIPT_VERSION="2023-12-06"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=samtools
TOOL_NAME=samtools
TOOL_DOCS=http://www.htslib.org/doc/samtools-merge.html
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/samtools
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true
version_only=false                 # When true, just print tool & script version info and exit

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
    echo "      sbatch $0 -i results/bwa -o results/merged.bam"
    echo "      sbatch $0 --fofn bamfiles.txt -o results/merged.bam"    
    echo "      sbatch $0 -o results/merged.bam results/bwa/A.bam results/bwa/B.bam results/bwa/C.bam"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -o/--outfile        <dir>   Output BAM file"
    echo "Specify the input using one of the following methods:"
    echo "  A) -i/--indir       <dir>   Input dir with BAM files (all BAM files in the dir will be used)"
    echo "  B) --fofn           <file>  File Of File Names (FOFN) with the input BAM files"
    echo "  C) Specify BAM files as positional arguments at the end of the command"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
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
        wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script"
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
declare -a infiles
indir=
fofn=
outdir=
tmpdir_arg=
more_opts=
threads=

# Parse command-line args
all_opts="$*"
count=0
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        --fofn )            shift && fofn=$1 ;;
        -o | --outfile )    shift && outfile=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --no_strict )       strict_bash=false ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
        * )                 infiles[count]=$1 && count=$(( count + 1 )) ;;
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
[[ -z "$outfile" ]] && die "No output file specified, do so with -o/--outfile" "$all_opts"
[[ -z "$indir" && ${#infiles[@]} -eq 0 ]] && die "Please specify input either using an input dir
    (-i/--indir), a FOFN (--fofn), or BAM files as positional args" "$all_opts"
[[ -n "$indir" && ! -d "$indir" ]] && die "Input dir $indir does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# Determine file name for unsorted BAM file
outdir=$(dirname "$outfile")

# Read BAM files into an array if an input dir is provided
[[ -n "$indir" ]] && mapfile -t infiles < <(find "$indir" -type f -name "*bam")
[[ -n "$fofn" ]] && mapfile -t infiles <"$fofn"

# Set temporary directory if this is a SLURM job
[[ "$IS_SLURM" == true ]] && tmpdir_arg="-T $TMPDIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "Output BAM file:                      $outfile"
echo "Number of threads/cores:              $threads"
echo "Number of input BAM files:            ${#infiles[@]}"
[[ -n $more_opts ]] && echo "Additional options for samtools sort: $more_opts"
log_time "Listing the input BAM files:"
for bam in "${infiles[@]}"; do ls -lh "$bam"; done
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY merge \
    $more_opts \
    -o - \
    "${infiles[@]}" |
    samtools sort \
        -@ "$threads" \
        -m 4G \
        $tmpdir_arg \
        > "$outfile"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
