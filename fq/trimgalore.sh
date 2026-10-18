#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=trimgalore
#SBATCH --output=slurm-trimgalore-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run TrimGalore for 1 (single-end) or 2 (paired-end) FASTQ file(s) for one sample"
SCRIPT_VERSION="2026-08-22"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=trim_galore
TOOL_NAME=TrimGalore
TOOL_DOCS=https://github.com/FelixKrueger/TrimGalore/blob/master/Docs/Trim_Galore_User_Guide.md
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container              # Use a 'conda' env or a Singularity 'container'
container_url=oras://community.wave.seqera.io/library/trim-galore:2.3.0--a56e49e832976df4
conda_path=
container_dir="$HOME"/containers
version_only=false

# Defaults - tool parameters
stringency=2               # => TrimGalore default is 1           (= min. adapter overlap) #!
quality=20                 # => 20 is also the TrimGalore default (= min. Phred score)
length=20                  # => 20 is also the TrimGalore default (= min. read length)
single_end=false           # => paired-end by default
two_color=false            # => Assume non-2-color chemistry (used by NextSeq/NovaSeq)
run_fastqc=true            # => Run FastQC after TrimGalore

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage (always submit your scripts to SLURM with 'sbatch'):"
    echo "      sbatch $0 -i data/fastq/S01_R1.fastq.gz -o results/trimgalore"
    echo "  - Provide custom adapter sequence:"
    echo "      sbatch $0 -i data/fastq/S01_R1.fastq.gz -o results/trimgalore --more_opts '--adapter ACGT'"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1         <file>  Gzipped (R1) FASTQ input file (if paired-end, R2 file name will be inferred)"
    echo "  -o/--outdir     <dir>   Output dir"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  -q/--quality    <int>   Quality trimming threshold         [default: $quality (also the $TOOL_NAME default)]"
    echo "  -l/--length     <int>   Minimum read length                [default: $length (also the $TOOL_NAME default)]"
    echo "  --stringency    <int>   Minimum adapter overlap length     [default: $stringency (NOTE: The TrimGalore default is 1)]"
    echo "  --single_end            Input is a single-end FASTQ file   [default: $single_end]"
    echo "  --2colour/--nextseq     Reads are from NextSeq/NovaSeq with 2-color chemistry"
    echo "                            This setting will help remove polyG tails [default: $two_color]"
    echo "  --no_fastqc             Don't run FastQC after trimming    [default: run FastQC]"
    echo "  --more_opts             Additional options to pass to $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type           <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --container_url <str>   URL to download the container from      [default: $container_url]"
    echo "  --container_dir <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --conda_env     <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  -h / --help             Print this help message and exit"
    echo "  -v                      Print the version of this script and exit"
    echo "  -v/--version            Print the version of $TOOL_NAME and exit"
    echo
    echo "OUTPUT:"
    echo "  Within the specified output dir (-o), results will be in 3 subdirectories:"
    echo "    - Trimmed FASTQ files will be in '<outdir>/trimmed/'"
    echo "    - FastQC output be in '<outdir>/fastqc/'"
    echo "    - Trimmomatic log files will be in '<outdir>/logs/'"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
    echo
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
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
R1_in=
R2_in=
outdir=
threads=
container_path=
fastqc_args=()
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )             shift && R1_in=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        -q | --quality )        shift && quality=$1 ;;
        -l | --length )         shift && length=$1 ;;
        --stringency )          shift && stringency=$1 ;;
        --single_end )          single_end=true ;;
        --2colour | --nextseq ) two_color=true ;;
        --no_fastqc )           run_fastqc=false ;;
        --more_opts )           shift && more_opts=$1 ;;
        --env_type )                 shift && env_type=$1 ;;
        --container_dir )       shift && container_dir=$1 ;;
        --container_url )       shift && container_url=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version )             version_only=true ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
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
set_threads "$IS_SLURM"

# Check options provided to the script
[[ -z "$R1_in" ]] && die "No input file specified, do so with -i/--R1" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$R1_in" ]] && die "Input file $R1_in does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
outdir_trim="$outdir"/trimmed && mkdir -p "$outdir_trim"
outdir_fastqc="$outdir"/fastqc && mkdir -p "$outdir_fastqc"

# FastQC arguments
if [[ "$run_fastqc" == true ]]; then
    fastqc_args=(--fastqc_args "-t $threads --outdir $outdir_fastqc")
fi

# NextSeq arg
if [[ "$two_color" == true ]]; then
    quality_arg="--nextseq $quality"
else
    quality_arg="--quality $quality"
fi

# Get file extension (.fastq.gz or .fq.gz)
file_ext=$(basename "$R1_in" | sed -E 's/.*(.fasta|.fastq.gz|.fq.gz)$/\1/')

# Get R2 file, create input argument, define output files
if [ "$single_end" != "true" ]; then
    # Paired-end sequences
    R1_suffix=$(basename "$R1_in" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
    R2_suffix=${R1_suffix/1/2}
    R2_in=${R1_in/$R1_suffix/$R2_suffix}
    input_arg="--paired $R1_in $R2_in"
    
    [[ ! -f "$R2_in" ]] && die "Input R2 FASTQ file $R2_in does not exist"
    [[ "$R1_in" == "$R2_in" ]] && die "Input R1 and R2 FASTQ files are the same file, $R1_in"

    sample_id=$(basename "$R1_in" "$file_ext" | sed -E "s/${R1_suffix}_?[[:digit:]]*//")
    R1_out="$outdir_trim"/"$sample_id"_R1.fastq.gz
    R2_out="$outdir_trim"/"$sample_id"_R2.fastq.gz
else
    # Single-end sequences
    input_arg="$R1_in"
    sample_id=$(basename "$R1_in" "$file_ext")
    R1_out="$outdir_trim"/"$sample_id".fastq.gz
fi

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo
echo "R1 input FASTQ file:                      $R1_in"
echo "Output dir:                               $outdir"
echo "Are sequences single-end?                 $single_end"
echo "Are sequences from NextSeq/NovaSeq?       $two_color"
echo "Run FastQC after trimming?                $run_fastqc"
echo
echo "TRIMMING THRESHOLDS:"
echo "Sequence quality threshold:               $quality"
echo "Minimum sequence length:                  $length"
echo "Minimum adapter overlap (stringency):     $stringency"
echo
[[ "$single_end" != "true" ]] && echo "R2 input FASTQ file (inferred):           $R2_in"
echo "Sample ID (inferred):                     $sample_id"
echo "R1 output file:            q               $R1_out"
[[ "$single_end" != "true" ]] && echo "R2 output file:                           $R2_out"
[[ -n $more_opts ]] && echo "Other options for $TOOL_NAME:             $more_opts"
log_time "Listing the input file(s):"
ls -lh "$R1_in"
[[ -n "$R2_in" ]] && ls -lh "$R2_in"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Run TrimGalore
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --output_dir "$outdir_trim" \
    $quality_arg \
    --length "$length" \
    --stringency "$stringency" \
    --cores "$threads" \
    "${fastqc_args[@]}" \
    $more_opts \
    $input_arg

# Process output files
log_time "Moving and renaming the output files..."
mv -v "$outdir_trim"/"$(basename "$R1_in")"_trimming_report.txt "$LOG_DIR"
if [ "$single_end" != "true" ]; then
    mv -v "$outdir_trim"/"$sample_id"*_val_1.fq.gz "$R1_out"
    mv -v "$outdir_trim"/"$sample_id"*_val_2.fq.gz "$R2_out"
else
    R1_basename="$(basename "$R1_in" "$file_ext")"
    mv -v "$outdir_trim"/"$R1_basename"_trimmed.fq.gz "$R1_out"
fi

# Final reporting
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
