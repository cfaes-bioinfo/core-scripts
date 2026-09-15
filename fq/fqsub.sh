#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --job-name=fqsub
#SBATCH --output=slurm-fqsub-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Script to subsample FASTQ files using seqtk"
SCRIPT_VERSION="2024-06-02"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="seqtk sample"
TOOL_NAME=seqtk
TOOL_DOCS=https://github.com/lh3/seqtk
VERSION_COMMAND="seqtk 2>&1 | sed -n '3p'"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/seqtk
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true

# Defaults - tool parameters
rand=$RANDOM
n_reads=100000
single_end=false

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i data/fastq/sampleA_R1.fastq.gz -o data/fastq_subset"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1             <file>  Input R1 FASTQ file (R2 file name will be inferred by the script)"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  -n/--n_reads        <int>   Number of reads to select               [default: 100,000]"
    echo "  -p/--prop_reads     <num>   Proportion of reads to select, e.g. '0.1' [default: off]"
    echo "  --single_end                Sequences are single-end                [default: paired-end]"
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
outdir=
prop_reads=
opts=
version_only=false

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1_in=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        -n | --n_reads )    shift && n_reads=$1 ;;
        -p | --prop_reads ) shift && prop_reads=$1 ;;
        --single_end )      single_end=true ;;
        --opts )            shift && opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --no_strict )       strict_bash=false ;;
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
[[ "$strict_bash" == true ]] && set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Infer the input dir and extension
indir=$(dirname "$R1_in")
extension=$(echo "$R1_in" | sed -E 's/.*(\.fa?s?t?q\.gz$)/\1/')

# FASTQ filename parsing
R1_basename=$(basename "$R1_in" | sed -E 's/.fa?s?t?q.gz//')
if [[ "$single_end" == false ]]; then
    # Paired-end sequences
    R1_suffix=$(echo "$R1_in" | sed -E 's/.*(_R?1).*fa?s?t?q.gz/\1/')
    R2_suffix=${R1_suffix/1/2}
    R2_in=${R1_in/$R1_suffix/$R2_suffix}
    
    [[ ! -f "$R2_in" ]] && die "Input R2 FASTQ file $R2_in does not exist"
    [[ "$R1_in" == "$R2_in" ]] && die "Input R1 and R2 FASTQ files are the same file, $R1_in"

    sample_id=${R1_basename/"$R1_suffix"/}
    R1_out="$outdir"/"$sample_id"_R1.fastq.gz
    R2_out="$outdir"/"$sample_id"_R2.fastq.gz
else
    sample_id=$(basename "$R1_in" | sed -E "s/${extension}//")
    R1_out="$outdir"/"$sample_id".fastq.gz
fi

# Check options provided to the script
[[ -z "$R1_in" ]] && die "No input file specified, do so with -i/--R1_in" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$R1_in" ]] && die "Input R1 FASTQ file $R1_in does not exist"
[[ -n "$R2_in" && ! -f "$R1_in" ]] && die "Input R2 FASTQ file $R2_in does not exist"
[[ "$indir" == "$outdir" ]] && Die "Input and output dirs can't be the same!"
[[ "$R1_in" == "$R2_in" ]] && Die "Name parsing error: input R1 and R2 are the same file!"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Output dir:                               $outdir"
echo "Input R1 FASTQ file:                      $R1_in"
[[ "$single_end" == false ]] && echo "Input R2 FASTQ file:                      $R2_in"
echo "Reads are single-end:                     $single_end"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$R1_in" "$R2_in"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# STEP A: Count nr of input reads ---------------------------------------------
log_time "Counting the number of reads in the input..."
# Number of reads in input FASTQ file:
n_total=$(zcat "$R1_in" | awk '{s++}END{print s/4}')
# If prop_reads is given, calculate n_reads:
[[ -n $prop_reads ]] && n_reads=$(python -c "print(int($n_total * $prop_reads))")
# Report:
echo "Input nr of reads:                        $n_total"
[[ $prop_reads != "" ]] && echo "Proportion of reads to keep:              $prop_reads"
echo "Output number of reads:                   $n_reads"

# STEP B: Run seqtk ------------------------------------------------------------
# Forward reads:
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -s$rand "$R1_in" "$n_reads" $opts | gzip > "$R1_out"
# Reverse reads:
if [[ "$single_end" == false ]]; then
    log_time "Running $TOOL_NAME for the reverse reads..."
    runstats $TOOL_BINARY \
        -s$rand "$R2_in" "$n_reads" | gzip > "$R2_out"
fi

# STEP C: Count reads in output ------------------------------------------------
log_time "Counting the number of reads in the output..."
n_R1_out=$(zcat "$R1_out" | awk '{s++}END{print s/4}')
[[ "$single_end" == false ]] && n_R2_out=$(zcat "$R2_out" | awk '{s++}END{print s/4}')
log_time "Number of reads in output file(s):"
echo "R1: $n_R1_out"
[[ "$single_end" == false ]] && echo "R2: $n_R2_out"

# Final reporting
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/"$sample_id"*
final_reporting "$LOG_DIR"
