#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=star_index
#SBATCH --output=slurm-star_index-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Index a genome or transcriptome with STAR"
SCRIPT_VERSION="2026-08-23"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=STAR
TOOL_NAME=STAR
TOOL_DOCS="https://github.com/alexdobin/STAR, https://github.com/alexdobin/STAR/blob/master/doc/STARmanual.pdf"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container
container_dir="$HOME/containers"
# Container with STAR v. 2.7.11b and samtools v. 1.23.1
container_url=oras://community.wave.seqera.io/library/samtools_star:952fa4513a08d418
container_path=
conda_path=

# Defaults - tool parameters
index_size="auto"
mem_bytes=4000000000

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
  - Basic usage:
      sbatch $0 -i data/ref/genome.fa --annot data/ref/annotation.gtf -o results/star_index

REQUIRED OPTIONS:
  -i/--infile       <file>  Input nucleotide FASTA file (genome or transcriptome)
  -o/--outdir       <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --annot           <file>  Reference annotation (GFF/GFF3/GTF) file
                             (GTF preferred)                                    [default: none, but recommended]
  --index_size      <int>   Index size                                          [default: $index_size => auto from genome size]
  --read_len        <int>   Read length (only applies with --annot)             [default: unset => overhang 99]
                            Determines the overhang length (read_len - 1).
  --more_opts       <str>   Quoted string with one or more additional options
                            for $TOOL_NAME

UTILITY OPTIONS:
  --env_type        <str>   Whether to use a Singularity/Apptainer container   [default: $env_type]
                            ('container') or a Conda environment ('conda')
  --container_url   <str>   URL to download a container from                   [default (if any): $container_url]
  --container_dir   <str>   Dir to download a container to                     [default: $container_dir]
  --container_path  <file>  Local container image file ('.sif') to use         [default (if any): $container_path]
  --conda_path      <dir>   Full path to a Conda environment to use            [default (if any): $conda_path]
  -h/--help                 Print this help message
  -v/--version              Print script and $TOOL_NAME versions

NOTES:
  The script will check how much memory has been allocated to the SLURM job (default: 64GB),
  and pass that to STAR via 'limitGenomeGenerateRAM'. When allocating more memory to the
  SLURM job (necessary for large genomes), this will be passed to STAR as well.

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
annot=
read_len=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --annot )           shift && annot=$1 ;;
        --index_size )      shift && index_size=$1 ;;
        --read_len )        shift && read_len=$1 ;;
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
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ -n "$annot" && ! -f "$annot" ]] && die "Annotation file $annot does not exist" "$all_opts"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"
[[ "$IS_SLURM" == true ]] && mem_bytes=$((SLURM_MEM_PER_NODE * 1000000))

# Build other arguments
annot_opt=
[[ -n "$annot" ]] && annot_opt="--sjdbGTFfile $annot"
overhang_opt=

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input assembly FASTA:                     $infile"
echo "Output dir:                               $outdir"
[[ -n "$annot" ]] && echo "Input annotation file:                    $annot"
[[ -n "$read_len" ]] && echo "Read length (for overhang size):          $read_len"
[[ "$index_size" != "auto" ]] && echo "Index size:                               $index_size"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ -n "$annot" ]] && ls -lh "$annot"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# STAR doesn't accept zipped FASTA files -- unzip if needed
if [[ $infile = *gz ]]; then
    infile_unzip=${infile/.gz/}
    if [[ ! -f $infile_unzip ]]; then
        log_time "Unzipping the currently gzipped FASTA file..."
        gunzip -c "$infile" > "$infile_unzip"
    else
        log_time "Using unzipped version of the FASTA file"
        ls -lh "$infile_unzip"
    fi
    infile="$infile_unzip"
fi

# Determine index size
if [[ "$index_size" == "auto" ]]; then
    log_time "Automatically determining the index size..."
    genome_size=$(grep -v "^>" "$infile" | wc -c)
    index_size=$(python -c "import math; print(math.floor(math.log($genome_size, 2)/2 -1))")
    log_time "Genome size (autom. determined):  $genome_size"
    log_time "Index size (autom. determined):   $index_size"
fi

# If read length is provided, determine overhang
if [[ -n "$read_len" ]]; then
    overhang=$(( read_len - 1 ))
    overhang_opt="--sjdbOverhang $overhang"
    log_time "Based on read length $read_len, setting overhang to: $overhang"
fi

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --runMode genomeGenerate \
    --limitGenomeGenerateRAM "$mem_bytes" \
    --genomeDir "$outdir" \
    --genomeFastaFiles "$infile" \
    --genomeSAindexNbases "$index_size" \
    --runThreadN "$threads" \
    $annot_opt \
    $overhang_opt \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
