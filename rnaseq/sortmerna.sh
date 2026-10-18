#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=5:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=sortmerna
#SBATCH --output=slurm-sortmerna-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run SortMeRNA to separate paired-end RNAseq reads into rRNA-derived and other reads
Separate pairs of FASTQ files with reads classified as rRNA (mapped) and reads not classified
as rRNA (unmapped)"
SCRIPT_VERSION="2023-08-10"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=sortmerna
TOOL_NAME=SortMeRNA
TOOL_DOCS=https://github.com/biocore/sortmerna
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/sortmerna-env
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true

# Constants - tool parameters
# Paths to rRNA reference files within the SortMeRNA repo dir
DB1=data/rRNA_databases/silva-euk-18s-id95.fasta  
DB2=data/rRNA_databases/silva-euk-28s-id98.fasta
DB3=data/rRNA_databases/silva-arc-16s-id95.fasta
DB4=data/rRNA_databases/silva-arc-23s-id98.fasta
DB5=data/rRNA_databases/silva-bac-16s-id90.fasta
DB6=data/rRNA_databases/silva-bac-23s-id98.fasta
DB7=data/rRNA_databases/rfam-5.8s-database-id98.fasta
DB8=data/rRNA_databases/rfam-5s-database-id98.fasta

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
    echo "      sbatch $0 -i data/S1_R1.fastq.gz -o results/sortmerna"
    echo "  - Loop:"
    echo "      for R1 in data/fastq/*R1.fastq.gz; do"
    echo "          sbatch $0 -i \$R1 -o results/sortmerna"
    echo "      done"
    echo
    echo "OUTPUT:"
    echo "  - Directory '<outdir>/by_sample/<sample_id> will contain e.g. SortMeRNA DB files and log files"
    echo "  - Directories '<outdir>/mapped' and '<outdir>/unmapped' will contain FASTQ files (for all samples)" 
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1             <file>  Input R1 FASTQ file (name of R2 will be inferred)"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "                                When running this script for multiple samples (looping over samples),"
    echo "                                please specify a single output dir for all of them (see example above)." 
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --repo              <dir>   Directory with SortMeRNA repo (with rRNA db) [default: download repo]"
    echo "  --as_is                     Don't 'de-interleave' output FASTQ file  [default: de-interleave]"
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
R1=
outdir=
opts=
version_only=false
threads=
repo_dir=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --repo )            repo_dir=false ;;
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

# Check options provided to the script
[[ -z "$R1" ]] && die "No input file specified, do so with -i/--R1" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$R1" ]] && die "Input file $R1 does not exist"

# Define outputs based on script parameters
# Infer the name of the R2 file
file_ext=$(basename "$R1" | sed -E 's/.*(.fastq.gz|.fq.gz)/\1/')
R1_suffix=$(basename "$R1" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
R2_suffix=${R1_suffix/1/2}
R2=${R1/$R1_suffix/$R2_suffix}
sample_id=$(basename "$R1" "$file_ext" | sed -E "s/${R1_suffix}_?[[:digit:]]*//")
[[ ! -f "$R2" ]] && die "Input file $R2 does not exist"
[[ "$R1" == "$R2" ]] && die "Input file $R1 and $R2 are the same ($R1)"

# Define output files
outdir_sample="$outdir"/by_sample/"$sample_id"
LOG_DIR="$outdir_sample"/logs
mapped_prefix="$outdir_sample"/mapped/"$sample_id"
unmapped_prefix="$outdir_sample"/unmapped/"$sample_id"
R1_mapped="$outdir"/mapped/"$sample_id""$R1_suffix".fastq.gz
R2_mapped="$outdir"/mapped/"$sample_id""$R2_suffix".fastq.gz
R1_unmapped="$outdir"/unmapped/"$sample_id""$R1_suffix".fastq.gz
R2_unmapped="$outdir"/unmapped/"$sample_id""$R2_suffix".fastq.gz

# Reference FASTA files (to be downloaded)
[[ -z $repo_dir ]] && repo_dir="$outdir_sample"/sortmerna_repo
DB1="$repo_dir"/"$DB1"
DB2="$repo_dir"/"$DB2"
DB3="$repo_dir"/"$DB3"
DB4="$repo_dir"/"$DB4"
DB5="$repo_dir"/"$DB5"
DB6="$repo_dir"/"$DB6"
DB7="$repo_dir"/"$DB7"
DB8="$repo_dir"/"$DB8"

# Make output dirs
mkdir -p "$LOG_DIR" "$repo_dir" "$outdir"/mapped "$outdir"/unmapped \

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "R1 input FASTQ:                           $R1"
echo "R2 input FASTQ:                           $R2"
echo "Output dir:                               $outdir"
echo "SortMeRNA repo dir:                       $repo_dir"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$R1" "$R2"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Remove kvdb dir if it already exists (or SortMeRNA will explainA)
[[ -d "$outdir_sample"/kvdb ]] && rm -rf "$outdir_sample"/kvdb

# Clone sortmerna repo to get db FASTA files
if [[ ! -f "$DB1" ]]; then
    log_time "Cloning SortMeRNA repo..."
    n_seconds=$(( RANDOM % 50 + 1 ))
    sleep "$n_seconds"s # Sleep for a while so git doesn't error when running this multiple times in parallel
    git clone https://github.com/biocore/sortmerna "$repo_dir"
fi
# Check that db files are there - just for the 1st one
[[ ! -f "$DB1" ]] && die "Reference FASTA file $DB1 not found"

# Run SortMeRNA
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --ref "$DB1" --ref "$DB2" --ref "$DB3" --ref "$DB4" \
    --ref "$DB5" --ref "$DB6" --ref "$DB7" --ref "$DB8" \
    --reads "$R1" \
    --reads "$R2" \
    --num_alignments 1 \
    --paired_in \
    --out2 \
    --fastx \
    --aligned "$mapped_prefix" \
    --other "$unmapped_prefix" \
    --workdir "$outdir_sample" \
    --threads "$threads" \
    $opts

#? --paired_in        => Flags the paired-end reads as Aligned, when either of them is Aligned.
#? --out2             => Output paired reads into separate files.                False
#? --num_alignments 1 => Outputs best alignment only, following nfc-rnaseq workflow

# Move & rename files
log_time "Moving output files..."
mv -v "$mapped_prefix"_fwd.fq.gz "$R1_mapped"
mv -v "$mapped_prefix"_rev.fq.gz "$R2_mapped"
mv -v "$unmapped_prefix"_fwd.fq.gz "$R1_unmapped"
mv -v "$unmapped_prefix"_rev.fq.gz "$R2_unmapped"
mv "$outdir_sample"/mapped/"$sample_id"*log "$LOG_DIR"
rmdir "$outdir_sample"/mapped "$outdir_sample"/unmapped

# Quantify mapping success
n_mapped=$(zcat "$R1_mapped" | awk '{s++} END{print s/4}')
n_unmapped=$(zcat "$R1_unmapped" | awk '{s++} END{print s/4}')
pct=$(python3 -c "print(round($n_mapped / ($n_unmapped + $n_mapped) * 100, 2))")
log_time "Number of reads mapped/unmapped, and % mapped:\t$sample_id\t$n_mapped\t$n_unmapped\t$pct"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
ls -lh "$R1_mapped" "$R2_mapped" "$R1_unmapped" "$R2_unmapped"
final_reporting "$LOG_DIR"
