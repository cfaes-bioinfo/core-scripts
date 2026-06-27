#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=fastp
#SBATCH --output=slurm-fastp-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run fastp to preprocess/QC FASTQ files"
SCRIPT_VERSION="2026-05-08"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=fastp
TOOL_NAME=fastp
TOOL_DOCS=https://github.com/OpenGene/fastp
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container
conda_path=
container_url=oras://community.wave.seqera.io/library/fastp:1.3.3--2a2d5feb1eb1082f
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
single_end=false
save_unpaired=false
min_length=15
max_length=0            # 0 means no max length filter
adapter=                # Empty means fastp auto-detection

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
      sbatch $0 -i data/A_R1.fastq.gz -o results/fastp

REQUIRED OPTIONS:
  -i/--R1             <file>  Input R1/forward FASTQ file (R2 name will be inferred)
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --single_end                Sequences are single-end: don't look for R2 file  [default: $single_end]
  --save_unpaired             Save unpaired (orphaned) reads in a single file   [default: $save_unpaired]
  --adapter           <str>   Adapter sequence to trim                          [default: auto-detect]
  --min_length        <int>   Minimum read length to keep                       [default: $min_length]
  --max_length        <int>   Maximum read length to keep (0 = no limit)        [default: $max_length]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

UTILITY OPTIONS:
  --env_type          <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                              ('container') or a Conda environment ('conda')
  --container_url     <str>   URL to download a container from                  [default (if any): $container_url]
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
R1_in=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1_in=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --single_end )      single_end=true ;;
        --save_unpaired )   save_unpaired=true ;;
        --adapter )         shift && adapter=$1 ;;
        --min_length )      shift && min_length=$1 ;;
        --max_length )      shift && max_length=$1 ;;
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
[[ -z "$R1_in" ]] && die "No input file specified, do so with -i/--R1" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$R1_in" ]] && die "Input file $R1_in does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
REPORT_DIR="$outdir"/reports
mkdir -p "$LOG_DIR" "$REPORT_DIR"

file_ext=$(basename "$R1_in" | sed -E 's/.*(.fasta|.fastq.gz|.fq.gz)$/\1/')
R1_suffix=$(basename "$R1_in" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
sample_id=$(basename "$R1_in" "$file_ext" | sed -E "s/${R1_suffix}_?[[:digit:]]*//")
R1_out="$outdir"/"$sample_id""$R1_suffix""$file_ext"

R2_arg=""
if [[ "$single_end" == false ]]; then
    R2_suffix=${R1_suffix/1/2}
    R2_in=${R1_in/$R1_suffix/$R2_suffix}
    [[ ! -f "$R2_in" ]] && die "Input file $R2_in does not exist"
    R2_out="$outdir"/"$sample_id""$R2_suffix""$file_ext"
    R2_arg="--in2 $R2_in --out2 $R2_out"
fi

unpaired_arg=""
if [[ "$save_unpaired" == true ]]; then
    [[ "$single_end" == true ]] && die "Can't save unpaired output when input is single-end"
    unpaired_out="$outdir"/"$sample_id"_unpaired"$file_ext"
    unpaired_arg="--unpaired1 $unpaired_out --unpaired2 $unpaired_out"
fi

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input R1 file:                            $R1_in"
[[ "$single_end" == false ]] && echo "Input R2 file:                            $R2_in"
echo "Output R1 file:                           $R1_out"
[[ "$single_end" == false ]] && echo "Output R2 file:                           $R2_out"
[[ "$save_unpaired" == true ]] && echo "Output unpaired file:                     $unpaired_out"
echo
echo "Single-end mode:                          $single_end"
echo "Save unpaired reads:                      $save_unpaired"
echo "Adapter sequence:                         ${adapter:-auto-detect}"
echo "Min read length:                          $min_length"
echo "Max read length:                          $max_length"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$R1_in"
[[ "$single_end" == false ]] && ls -lh "$R2_in"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
length_opts="--length_required $min_length"
[[ "$max_length" -gt 0 ]] && length_opts="$length_opts --length_limit $max_length"
adapter_arg=""
[[ -n "$adapter" ]] && adapter_arg="--adapter_sequence $adapter"

runstats $TOOL_BINARY \
    --in1 "$R1_in" \
    --out1 "$R1_out" \
    $R2_arg \
    $unpaired_arg \
    $adapter_arg \
    $length_opts \
    --json "$REPORT_DIR"/"$sample_id".json \
    --html "$REPORT_DIR"/"$sample_id".html \
    --thread "$threads" \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
