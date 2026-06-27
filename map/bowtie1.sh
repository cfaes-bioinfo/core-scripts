#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=20G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bowtie1
#SBATCH --output=slurm-bowtie1-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Map single-endreads to a reference genome with Bowtie1 and sort the BAM with samtools"
SCRIPT_VERSION="2026-06-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=
TOOL_NAME=Bowtie
TOOL_DOCS=https://bowtie-bio.sourceforge.net/index.shtml
VERSION_COMMAND="$TOOL_BINARY bowtie --version"

# Defaults - generics
env_type=container
conda_path=
container_url=oras://community.wave.seqera.io/library/bowtie_samtools:b5ddb8d24794f560
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
max_alignments=1       # Report up to this many valid alignments per read (-k)
report_all=false       # Report all valid alignments (-a); overrides -k
max_mismatches=2       # Max mismatches in the entire read (-v)
best_strata=true       # Use --best --strata for best-stratum alignments
exclude_unmapped=false
unmapped_out=          # Output unmapped reads to FASTQ file (--un)

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
      sbatch $0 -i data/reads.fastq.gz --index results/bowtie1_index/genome -o results/bowtie1

REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTQ file (single-end reads)
  --index             <str>   Bowtie1 index prefix (as created by bowtie-build)
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  -k/--max_alignments <int>   Report up to this many valid alignments per read  [default: $max_alignments]
  -a/--report_all             Report all valid alignments (overrides -k)        [default: $report_all]
  --max_mismatches    <int>   Max number of mismatches in the entire read (0-3) [default: $max_mismatches]
  --no_best_strata            Don't use --best --strata (best-stratum reporting)[default: best_strata=$best_strata]
  --exclude_unmapped          Exclude unmapped reads from the output BAM        [default: $exclude_unmapped]
  --unmapped_out      <dir>   Write unmapped reads to FASTQ file(s) in this dir [default: off]
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
infile=
index=
best_opts=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )         shift && infile=$1 ;;
        --index )               shift && index=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        -k | --max_alignments ) shift && max_alignments=$1 ;;
        -a | --report_all )     report_all=true ;;
        --max_mismatches )      shift && max_mismatches=$1 ;;
        --no_best_strata )      best_strata=false ;;
        --exclude_unmapped )    exclude_unmapped=true ;;
        --unmapped_out )        shift && unmapped_out=$1 ;;
        --more_opts )           shift && more_opts=$1 ;;
        --env_type )            shift && env_type=$1 ;;
        --conda_path )          shift && conda_path=$1 ;;
        --container_dir )       shift && container_dir=$1 ;;
        --container_url )       shift && container_url=$1 ;;
        --container_path )      shift && container_path=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version)         version_only=true ;;
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
load_env "$env_type" "$conda_path" "$container_dir" "$container_path" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$index" ]] && die "No index prefix specified, do so with --index" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"
sample_id=$(basename "${infile%%.*}")
outfile="$outdir"/"$sample_id".bam


# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "Index prefix:                             $index"
echo "Output dir:                               $outdir"
echo "Output BAM file:                          $outfile"
echo
echo "Report all alignments (-a):               $report_all"
echo "Max alignments per read (-k):             $max_alignments"
echo "Max mismatches per read (-v):             $max_mismatches"
echo "Use --best --strata:                      $best_strata"
echo "Exclude unmapped reads:                   $exclude_unmapped"
echo "Write unmapped reads to:                  ${unmapped_out:-off}"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
[[ "$best_strata" == true ]] && best_opts="--best --strata"

if [[ "$report_all" == true ]]; then
    align_opts="-a"
else
    align_opts="-k $max_alignments"
fi

un_opts=""
if [[ -n "$unmapped_out" ]]; then
    mkdir -p "$unmapped_out"
    un_opts="--un ${unmapped_out}/${sample_id}_unmapped.fastq"
fi

if [[ "$exclude_unmapped" == true ]]; then
    runstats $TOOL_BINARY bowtie \
        -x "$index" \
        "$infile" \
        $align_opts \
        -v "$max_mismatches" \
        $best_opts \
        $un_opts \
        --threads "$threads" \
        --sam \
        $more_opts |
        runstats $TOOL_BINARY samtools view -@ "$threads" -F 4 -b |
        runstats $TOOL_BINARY samtools sort -@ "$threads" -o "$outfile"
else
    runstats $TOOL_BINARY bowtie \
        -x "$index" \
        "$infile" \
        $align_opts \
        -v "$max_mismatches" \
        $best_opts \
        $un_opts \
        --threads "$threads" \
        --sam \
        $more_opts |
        runstats $TOOL_BINARY samtools sort -@ "$threads" -o "$outfile"
fi

log_time "Indexing the BAM file..."
runstats $TOOL_BINARY samtools index -@ "$threads" "$outfile"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
