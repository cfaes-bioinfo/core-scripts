#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bwa-mem2
#SBATCH --output=slurm-bwa-mem2-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Map short reads to a reference using BWA MEM, and output a sorted BAM file and a 'samtools flagstat' QC stats file"
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
SCRIPT_VERSION="2026-03-12"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=
TOOL_NAME=BWA-MEM2
TOOL_DOCS=https://github.com/bwa-mem2/bwa-mem2
VERSION_COMMAND="bwa-mem2 version | head -n2"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
# Container has bwa-mem2 2.2.1 and samtools 1.23
container_url=oras://community.wave.seqera.io/library/bwa-mem2_samtools:476d7bb598607d10
container_dir="$HOME/containers"
container_path=

# Option defaults
single_end=false            # Assume that reads are PE
use_secondary=true          # Use bwa mem's -M option: output additional shorter hits as secondary


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
      sbatch $0 -i TODO -o results/TODO
    
REQUIRED OPTIONS:
  -i/--R1             <file>  Input FASTQ file (for paired-end: only pass R1;
                              R2 will be inferred)
  --index_dir         <dir>   Input genome index directory (with bwa index files)
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --no_secondary              Don't use BWA MEM's '-M' option to output shorter
                              additional hits as 'secondary'                    [default: use -M]
  --readgroup         <str>   Readgroup string to be added to the BAM file
  --single_end                Reads are single-end - don't look for R2 file     [default: PE reads]
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
version_only=false  # When true, just print tool & script version info and exit
infile=
outdir=
index_dir=
R2=
readgroup_string= && readgroup_arg=
threads=
more_opts=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && infile=$1 ;;
        --index_dir )       shift && index_dir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --single_end )      single_end=true ;;
        --no_secondary )    use_secondary=false ;;
        --readgroup )       shift && readgroup_string=$1 ;;
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
[[ -z "$infile" ]] && die "No input FASTQ file specified, do so with -i/--R1" "$all_opts"
[[ -z "$index_dir" ]] && die "No input index dir specified, do so with --index_dir" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -d "$index_dir" ]] && die "Input index dir $index_dir does not exist"

# Determine R2 file, output prefix, etc
if [[ -n "$infile" ]]; then
    R1_basename=$(basename "$infile" | sed -E 's/.fa?s?t?q.gz//')
    
    if [[ "$single_end" == false ]]; then
        R1_suffix=$(echo "$infile" | sed -E 's/.*(_R?1).*fa?s?t?q.gz/\1/')
        sampleID=${R1_basename/"$R1_suffix"/}

        # Determine name of R2 file
        if [[ -z "$R2" ]]; then
            R2_suffix=${R1_suffix/1/2}
            R2=${infile/$R1_suffix/$R2_suffix}
        fi
        
        [[ ! -f "$R2" ]] && die "R2 input file $R2 does not exist"
        [[ "$infile" == "$R2" ]] && die "Input file R1 is the same as R2 ($infile)"
    
    else
        sampleID="$R1_basename"
    fi
fi

# Reference index prefix
n_index=$(find "$index_dir" -name "*amb" | wc -l)
[[ "$n_index" == 0 ]] && die "No BWA index files found in index dir $index_dir"
[[ "$n_index" -gt 1 ]] && log_time "WARNING: More than one BWA indices found, using the first"
index_prefix=$(find "$index_dir" -name "*amb" | head -n 1 | sed 's/.amb//')

# Other
[[ -n "$readgroup_string" ]] && readgroup_arg="-R $readgroup_string"
if [[ "$use_secondary" == true ]]; then secondary_arg="-M"; else secondary_arg=; fi
bam=$outdir/"$sampleID".bam
flagstat_file="$outdir"/flagstat/"$sampleID".flagstat

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs 
mkdir -p "$LOG_DIR" "$outdir"/flagstat

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input (R1) FASTQ file:                    $infile"
[[ -n "$R2" ]] && echo "Input R2 FASTQ file:                      $R2"
echo "Reads are single end:                     $single_end"
echo "Shorter hits are output as secondary:     $use_secondary"
echo "Index prefix:                             $index_prefix"
echo "Output BAM file:                          $bam"
echo "Output flagstat file:                     $flagstat_file"
[[ -n "$readgroup_string" ]] && echo "Readgroup string:                         $readgroup_string"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY bwa-mem2 mem \
    -t "$threads" \
    $readgroup_arg \
    $secondary_arg \
    $more_opts \
    "$index_prefix" \
    "$infile" \
    "$R2" |
    runstats $TOOL_BINARY samtools sort \
    --threads "$threads" \
    -o "$bam" -

#-o "$outdir"/test.sam \

#? Useful bwa flags:
#?  -t nr of threads
#?  -a alignments for single-end / unpaired reads are also output, as secondary alignments
#?  -M shorter split reads are output as secondary alignments, for Picard compatibility
#?  -R "@RG\tID:group1\tSM:$IND\tPL:illumina\tLB:lib1"

# Get mapping stats
log_time "Getting mapping stats with Samtools flagstat:"
$TOOL_BINARY samtools flagstat "$bam" > "$flagstat_file"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
# List the output
log_time "Listing the output BAM file:"
ls -lh "$bam"
log_time "Number of mapped reads:"
grep "primary mapped" "$flagstat_file"
[[ -n "$R2" ]] && grep "properly paired" "$flagstat_file" 
final_reporting "$LOG_DIR"
