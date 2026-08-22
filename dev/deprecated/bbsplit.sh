#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bbsplit
#SBATCH --output=slurm-bbsplit-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run BBSplit to 'competitively' map reads to two or three separate genomes"
SCRIPT_VERSION="2023-12-15"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=bbsplit.sh
TOOL_NAME=BBSplit
TOOL_DOCS=https://jgi.doe.gov/data-and-tools/software-tools/bbtools/bb-tools-user-guide/bbmap-guide/
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/bbmap
container_path=
container_url=
container_dir="$HOME/containers"

# Defaults - tool parameters
single_end=false
ambiguous2="split"

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
    echo "      sbatch $0 -i sampleA.fastq.gz --ref1 assemblyA.fasta --ref2 assemblyB.fasta -o results/bbsplit"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1             <file>  R1 input FASTQ file (name of R2 file will be inferred unless --single_end is used)"
    echo "  --ref1              <file>  First reference genome FASTA file"
    echo "  --ref2              <file>  Second reference genome FASTA file"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --ref3              <file>  Third reference genome FASTA file"
    echo "  --ambiguous2        <str>   Set behavior only for reads that map ambiguously to multiple different references"
    echo "                              'best', 'toss', 'all', or 'split'       [default: $ambiguous2]"
    echo "  --single_end                Sequences are single-end; don't look for R2 file"
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
version_only=false                 # When true, just print tool & script version info and exit
R1= && R2=
ref1= && ref2= && ref3=
outdir=
opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1=$1 ;;
        --ref1 )            shift && ref1=$1 ;;
        --ref2 )            shift && ref2=$1 ;;
        --ref3 )            shift && ref3=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --ambiguous2 )      shift && ambiguous2=$1 ;;
        --opts )            shift && opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --single_end )      single_end=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
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
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$R1" ]] && die "No R1 input file specified, do so with -i/--R1" "$all_opts"
[[ -z "$ref1" ]] && die "No first reference genome file specified, do so with --ref1" "$all_opts"
[[ -z "$ref2" ]] && die "No second reference genome file specified, do so with --ref2" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$R1" ]] && die "Input R1 file $R1 does not exist"
[[ ! -f "$ref1" ]] && die "First reference genome file $ref1 does not exist"
[[ ! -f "$ref2" ]] && die "Second reference genome file $ref2 does not exist"
[[ -n "$ref3" && ! -f "$ref2" ]] && die "Second reference genome file $ref2 does not exist"

# Define outputs based on script parameters
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"
[[ ! "$R1" =~ ^/ ]] && R1="$PWD"/"$R1"
[[ ! "$ref1" =~ ^/ ]] && ref1="$PWD"/"$ref1"
[[ ! "$ref2" =~ ^/ ]] && ref2="$PWD"/"$ref2"
[[ -n "$ref3" && ! "$ref3" =~ ^/ ]] && ref3="$PWD"/"$ref3"
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

file_ext=$(basename "$R1" | sed -E 's/.*(.fasta|.fastq.gz|.fq.gz)$/\1/')
R1_suffix=$(basename "$R1" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
sample_id=$(basename "$R1" "$file_ext" | sed -E "s/${R1_suffix}_?[[:digit:]]*//")

# Define R2
if [[ "$single_end" == false ]]; then
    R2_suffix=${R1_suffix/1/2}
    R2=${R1/$R1_suffix/$R2_suffix}
    [[ ! -f "$R2" ]] && die "Input R2 file $R2 does not exist"
fi

# Set memory
if [[ "$IS_SLURM" == true ]]; then
    mem=$(( SLURM_MEM_PER_NODE - 2500 ))M
else
    mem=4000M
fi

# Reference genome option
if [[ -n "$ref3" ]]; then
    ref_opt="$ref1","$ref2","$ref3"
else
    ref_opt="$ref1","$ref2"
fi

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input R1 FASTQ file:                      $R1"
[[ "$single_end" == "false" ]] && echo "Input R2 FASTQ file:                      $R2"
echo "First reference genome FASTA:             $ref1"
echo "Second reference genome FASTA:            $ref2"
[[ -n "$ref3" ]] && echo "Third reference genome FASTA:             $ref3"
echo "Reference option:                         $ref_opt"
echo "What to do with ambiguously mapping reads: $ambiguous2"
echo "Input reads are single-end:               $single_end"
echo "Output dir:                               $outdir"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$R1" "$ref1" "$ref2"
[[ -n "$ref3" ]] && ls -lh "$ref3"
[[ "$single_end" == "false" ]] && ls -lh "$R2"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Moving into the output dir $outdir..."
cd  "$outdir" || exit

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    in="$R1" \
    in2="$R2" \
    ref="$ref_opt" \
    ambiguous2="$ambiguous2" \
    basename="$outdir"/"$sample_id"_%.fq \
    scafstats="$outdir"/"$sample_id"_scafstats.txt \
    refstats="$outdir"/"$sample_id"_refstats.txt \
    maxindel=150000 \
    threads="$threads" \
    -Xmx"$mem" \
    $opts

#? maxindel=150000 from nf-core RNAseq workflow
#? nf-core rnaseq workflow has ambigous2=all

log_time "Showing the contents of the 'refstats' file:"
column -t "$outdir"/"$sample_id"_refstats.txt

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
