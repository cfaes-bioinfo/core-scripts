#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=8:00:00
#SBATCH --cpus-per-task=20
#SBATCH --mem=80G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=inspector
#SBATCH --output=slurm-inspector-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Inspector to check the quality of a genome assembly"
SCRIPT_VERSION="2026-05-24"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=inspector.py
TOOL_NAME=Inspector
TOOL_DOCS="https://github.com/ChongLab/Inspector / https://github.com/Maggi-Chen/Inspector"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
#! NOTE: Had updated to container v1.3.1 but the inspector-correct script does not work there somehow
env_type=conda
conda_path=/fs/ess/PAS2380/assembly/jelmer/software/envs/inspector-1.0.2
container_dir="$HOME/containers"
container_url=oras://community.wave.seqera.io/library/inspector:1.3.1--68e9c83c212ac2b6
container_path=

# Defaults - tool parameters
datatype=nanopore

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
      sbatch $0 --assembly results/assembly/my.fasta --reads reads.fastq.gz -o results/inspector

REQUIRED OPTIONS:
  --assembly        <file>  Input assembly FASTA file
  --reads           <file>  Input FASTQ file with long (PacBio/ONT) reads
  -o/--outdir       <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --datatype        <str>   Input read type: 'nanopore' / 'clr' / 'hifi' / 'mixed'
                                                                        [default: $datatype]
  --ref_fa          <file>  Reference genome nucleotide FASTA file
  --more_opts       <str>   Quoted string with one or more additional options
                            for $TOOL_NAME

UTILITY OPTIONS:
  --env_type        <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                            ('container') or a Conda environment ('conda')
  --container_url   <str>   URL to download a container from                  [default (if any): $container_url]
  --container_dir   <str>   Dir to download a container to                    [default: $container_dir]
  --container_path  <file>  Local container image file ('.sif') to use        [default (if any): $container_path]
  --conda_path      <dir>   Full path to a Conda environment to use           [default: $conda_path]
  -h/--help                 Print this help message
  -v/--version              Print script and $TOOL_NAME versions

TOOL DOCUMENTATION:
  $TOOL_DOCS
"
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
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -f "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -f "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script_name"
        fi
        source "$function_script_name"
    fi
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false
assembly=
reads=
outdir=
ref_fa=
datatype=nanopore
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --assembly )        shift && assembly=$1 ;;
        --reads )           shift && reads=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --ref_fa )          shift && ref_fa=$1 ;;
        --datatype )        shift && datatype=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --conda_path )      shift && conda_path=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
        --container_path )  shift && container_path=$1 ;;
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
load_env "$env_type" "$conda_path" "$container_dir" "$container_path" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$assembly" ]] && die "No assembly specified, do so with --assembly" "$all_opts"
[[ -z "$reads" ]] && die "No reads file specified, do so with --reads" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$assembly" ]] && die "Input assembly file $assembly does not exist"
[[ ! -f "$reads" ]] && die "Input reads file $reads does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

# Build other arguments
ref_fa_opt=
[[ -n "$ref_fa" ]] && ref_fa_opt="--ref $ref_fa"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input assembly FASTA:                     $assembly"
echo "Input reads FASTQ:                        $reads"
echo "Output dir:                               $outdir"
echo "Data type:                                $datatype"
[[ -n $ref_fa ]] && echo "Reference FASTA file:                     $ref_fa"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$assembly" "$reads"
[[ -n "$ref_fa" ]] && ls -lh "$ref_fa"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --contig "$assembly" \
    --read "$reads" \
    --datatype "$datatype" \
    --thread "$threads" \
    -o "$outdir" \
    $ref_fa_opt \
    $more_opts

echo -e "\n# Showing the summary statistics file $outdir/summary_statistics:"
cat "$outdir"/summary_statistics

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
