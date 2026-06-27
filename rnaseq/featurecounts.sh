#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=5:00:00
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=featurecounts
#SBATCH --output=slurm-featurecounts-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Use featureCounts to create a matrix with per-gene read counts, from a directory of BAM files.
    NOTE - by default, reads are assumed to be paired-end (--read_type paired), and these
    featureCounts options are then used: -p, --countReadPairs, -B, -C.
    Set '--read_type single' to run for single-end reads.
    "
SCRIPT_VERSION="2026-05-10"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=featureCounts
TOOL_NAME=featureCounts
VERSION_COMMAND="$TOOL_BINARY -v"

# Defaults - generics
env_type=container                           # Use a 'conda' env or a Singularity 'container'
conda_path=
container_path=oras://community.wave.seqera.io/library/subread:2.1.1--bae420bffb4edf16
container_url=
dl_container=false
container_dir="$HOME/containers"
version_only=false                 # When true, just print tool & script version info and exit

# Defaults - tool parameters
strand=reverse
feature_type=exon                  # Same default as featureCounts itself
read_type=paired
count_multimap=true && multimap_opt="-M" # Count reads that mapped to multiple locations (-M option)
use_fraction=true && fraction_opt="--fraction"

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
    echo "      sbatch $0 -i results/STAR --annot data/ref/my.gff -o results/featurecounts/counts.tsv"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <dir>   Dir with input BAM files"
    echo "  -a/--annot          <file>  Input reference annotation (GFF/GTF) file"
    echo "  -o/--outfile        <dir>   Count matrix output file (dir will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --strand            <str>   Strandedness, either 'forward', 'reverse', or 'unstranded'     [default: 'reverse']"
    echo "  --read_type         <str>   Read type: 'paired' or 'single'         [default: 'paired']"
    echo "                              (This should correspond to a value in the 3rd column in the GFF/GTF file)"
    echo "  --feature_type      <str>   Feature type to count                   [default: 'exon']"
    echo "  --gene_key          <str>   Key (identifier) for the gene ID        [default: 'Name' for GFF, 'gene_id' for GTF]"
    echo "  --no_multimap               Don't count multi-mapped reads          [default: count multi-mapped reads with featureCounts' -M option]"
    echo "  --no_fraction               Don't use featureCounts' --fraction option [default: $use_fraction]"
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type          <str>   Use a Singularity container ('container')
                                        or a Conda env ('conda')                [default: $env_type]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v/--version                Print the version of this script and $TOOL_NAME and exit"
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
indir=
outfile=
annot=
more_opts=
threads=
gene_key=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outfile )    shift && outfile=$1 ;;
        -a | --annot )      shift && annot=$1 ;;
        --strand )          shift && strand=$1 ;;
        --feature_type )    shift && feature_type=$1 ;;
        --read_type )       shift && read_type=$1 ;;
        --gene_key )        shift && gene_key=$1 ;;
        --no_multimap )     count_multimap=false && multimap_opt= ;;
        --no_fraction )     use_fraction=false && fraction_opt= ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
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
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$indir" ]] && die "No input dir specified, do so with -i/--indir" "$all_opts"
[[ -z "$outfile" ]] && die "No output file specified, do so with -o/--outfile" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# Define outputs based on script parameters
outdir=$(dirname "$outfile")
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# RNA-seq library strandedness
if [[ $strand == "reverse" ]]; then
    strand_opt="-s 2"
elif [[ $strand == "forward" ]]; then
    strand_opt="-s 1"
elif [[ $strand == "unstranded" ]]; then
    strand_opt=
else
    die "RNAseq library strandedness ('--strand') is $strand but should be one of 'forward', 'reverse', or 'unstranded'"
fi

# Read type and featureCounts options
if [[ $read_type == "paired" ]]; then
    paired_opts="-p --countReadPairs -B -C"
elif [[ $read_type == "single" ]]; then
    paired_opts=
else
    die "Read type ('--read_type') is $read_type but should be 'paired' or 'single'"
fi

if [[ "$use_fraction" == true && "$count_multimap" == false ]]; then
    die "--fraction was requested while multi-mapping reads are disabled (--no_multimap). --fraction only applies when counting multi-mapped reads (-M)."
fi

# Annotation format
if [[ -z "$gene_key" ]]; then
    if [[ "$annot" =~ .*\.gff3? ]]; then
        log_time "Annotation format is GFF, setting aggregation ID to 'Name'"
        gene_key="Name"
    elif [[ "$annot" =~ .*\.gtf ]]; then
        log_time "Annotation format is GTF, setting aggregation ID to 'gene_id'"
        gene_key="gene_id"
    else
        die "Unknown annotation file format"
    fi
fi

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input dir with BAM files:                 $indir"
echo "Annotation file:                          $annot"
echo "Output file:                              $outfile"
echo "Library strandedness:                     $strand"
echo "Read type:                                $read_type"
echo "Feature type in GFF/GTF:                  $feature_type"
echo "Gene ID key in GFF/GTF:                   $gene_key"
echo "Count multi-mapping reads?                $count_multimap"
echo "Use fractional multi-map assignment?      $use_fraction"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input BAM file(s):"
ls -lh "$indir"/*bam
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    $strand_opt \
    $multimap_opt \
    $fraction_opt \
    -t "$feature_type" \
    -g "$gene_key" \
    -a "$annot" \
    -o "$outfile" \
    -T "$threads" \
    $paired_opts \
    $more_opts \
    "$indir"/*bam

# Options used:
#? -s 2             => Reverse-stranded library like TruSeq
#? -p               => Count fragments for paired-end reads
#? --countReadPairs => Count fragments, not reads (paired-end)
#? -B               => Require both members of a read pair to be aligned (paired-end)
#? -C               => Don't count pairs with discordant mates (paired-end)
#? -M               => Include multi-mapping reads

# Other possible options:
#? -O               => Assign reads that overlap multiple features
#? --minOverlap => Min nr of overlapping bases required for read assignnment (default: 1)


log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
