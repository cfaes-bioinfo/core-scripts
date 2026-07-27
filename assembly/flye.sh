#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=20:00:00
#SBATCH --cpus-per-task=40
#SBATCH --mem=172G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=flye
#SBATCH --output=slurm-flye-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Flye to assemble a genome with long reads"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=flye
TOOL_NAME=Flye
TOOL_DOCS=https://github.com/fenderglass/Flye/blob/flye/docs/USAGE.md
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
#? 2024-09-24: Using a container by default because I regularly get malloc and core dumping with the Conda env
env_type=container                                    # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/flye:2.9.6--0c4130a5dcdcfcbf
container_path=
container_dir="$HOME/containers"
version_only=false                 # When true, just print tool & script version info and exit

# Defaults - tool parameters
iterations=1
resume=false && resume_opt=

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
    echo "      sbatch $0 -i data/minion/my.fastq -o results/flye"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -o/--outfile        <file>  Output assembly FASTA file (use extension '.fa' or '.fasta')"
    echo "  --read_type         <str>   Read type, one of: 'pacbio-raw', 'pacbio-corr', 'pacbio-hifi',
                                          'nano-raw', 'nano-corr', 'nano-hq' -- see Flye help for details"
    echo "To specify the input read files, use one of the two following options:"
    echo "  -i/--reads          <file>  One or more input FASTQ files"
    echo "                                In case of multiple files, quote the entire string and space-separate paths, e.g.:"
    echo "                                -i \"data/minion/file1.fastq data/minion/file1.fastq\""
    echo "  --fofn              <file>  Text file with list of input FASTQ files one per line (File OF File Names, fofn)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --genome_size       <str>   Genome size estimate, e.g '4.6m' or '1g'    [default: no estimate]"
    echo "  --iterations        <int>   Number of polishing iterations              [default: 1]"
    echo "  --resume                    Resume previous run"
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type          <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v/--version                Print the version of this script and of $TOOL_NAME and exit"
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
fofn=
outfile=
read_type=
genome_size= && genome_size_opt=
more_opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && IFS=" " read -r -a infiles <<< "$1" ;;
        --fofn )            shift && fofn=$1 ;;
        -o | --assembly )   shift && outfile=$1 ;;
        --genome_size )     shift && genome_size=$1 ;;
        --read_type )       shift && read_type=$1 ;;
        --iterations )      shift && iterations=$1 ;;
        --resume )          resume=true && resume_opt="--resume" ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )    version_only=true ;;
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
load_env "$conda_path" "$container_path"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ ${#infiles[@]} = 0 && "$fofn" = "" ]] && die "No input file specified, do so with -i/--reads or --fofn" "$all_opts"
[[ -z "$outfile" ]] && die "No output file specified, do so with -o/--assembly" "$all_opts"

# Define outputs based on script parameters
outdir=$(dirname "$outfile")
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
# If a FOFN was provided, read file list into an array
[[ "$fofn" != "" ]] && mapfile -t infiles <"$fofn"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo
[[ "$fofn" != "" ]] && echo "File with list of FASTQs (fofn):      $fofn"
echo "Input files with reads:               ${infiles[*]}"
echo "Number of input files:                ${#infiles[*]}"
echo "Input read type:                      $read_type"
echo "Output assembly file:                 $outfile"
echo "Genome size:                          $genome_size"
echo "Nr of polishing iterations:           $iterations"
echo "Resume previous run:                  $resume"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
for infile in "${infiles[@]}"; do
    [[ ! -f $infile ]] && die "Input file $infile does not exist!"
    ls -lh "$infile"
done
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --$read_type "${infiles[@]}" \
    --out-dir "$outdir" \
    --iterations "$iterations" \
    --threads "$threads" \
    $resume_opt \
    $genome_size_opt \
    $more_opts

# Copy assembly FASTA
echo -e "\n# Copying the assembly FASTA file:"
cp -v "$outdir"/assembly.fasta "$outfile"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
