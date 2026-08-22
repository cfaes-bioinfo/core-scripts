#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bbmap
#SBATCH --output=slurm-bbmap-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
readonly DESCRIPTION="Map PE FASTQ files to a reference FASTA using BBmap"
readonly MODULE=miniconda3/4.12.0-py39
readonly CONDA=/fs/ess/PAS0471/jelmer/conda/bbmap
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
readonly TOOL_BINARY=bbmap.sh
readonly TOOL_NAME=BBmap
readonly TOOL_DOCS=https://jgi.doe.gov/data-and-tools/software-tools/bbtools/bb-tools-user-guide/bbmap-guide
readonly VERSION_COMMAND="$TOOL_BINARY --version"

# Constants - parameters
SETTINGS="k=14 minid=0.9 build=1"

# Parameter defaults
rm_unsorted=true

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo
    echo "        $0 (v. $SCRIPT_VERSION): Run $TOOL_NAME"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage (always submit your scripts to SLURM with 'sbatch'):"
    echo "      sbatch $0 -i data/sampleA_R1.fastq.gz --ref data/assembly.fa -o results/bbmap/sampleA"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--R1         <file>  R1 input FASTQ file (name of R2 will be inferred)"
    echo "  --ref           <file>  Reference FASTA file"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_args     <str>   Quoted string with additional argument(s) for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help               Print this help message and exit"
    echo "  -v                      Print the version of this script and exit"
    echo "  --version               Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
    echo
}

# Function to source the script with Bash functions
source_function_script() {
    local is_slurm=$1

    # Determine the location of this script, and based on that, the function script
    if [[ "$is_slurm" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script=$(realpath "$script_dir"/../dev/bash_functions.sh)
    
    if [[ ! -f "$function_script" ]]; then
        echo "Can't find script with Bash functions ($function_script), downloading from GitHub..."
        git clone https://github.com/mcic-osu/mcic-scripts.git
        function_script=mcic-scripts/dev/bash_functions.sh
    fi
    source "$function_script"
}

# ==============================================================================
#                          INFRASTRUCTURE SETUP I
# ==============================================================================
# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
R1= && R2=
ref=
outdir=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && readonly R1=$1 ;;
        -o | --outdir )     shift && readonly outdir=$1 ;;
        -r | --ref )        shift && readonly ref=$1 ;;
        --more_args )       shift && readonly more_args=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         load_env "$MODULE" "$CONDA"
                            print_version "$VERSION_COMMAND" && exit 0 ;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check arguments
[[ -z "$R1" ]] && die "No input R1 file specified, do so with -i/--R1" "$all_args"
[[ -z "$ref" ]] && die "No reference FASTA file specified, do so with -r/--ref1" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -f "$R1" ]] && die "R1 input file $R1 does not exist"
[[ ! -f "$ref" ]] && die "Reference FASTA file $ref does not exist"


# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Define outputs based on script parameters
R1_basename=$(basename "$R1" | sed -E 's/.fa?s?t?q.gz//')
R1_suffix=$(echo "$R1" | sed -E 's/.*(_R?1).*fa?s?t?q.gz/\1/')
sample_id=${R1_basename/"$R1_suffix"/}
R2_suffix=${R1_suffix/1/2}
R2=${R1/$R1_suffix/$R2_suffix}
[[ ! -f "$R2" ]] && die "R2 input file $R2 does not exist"
[[ "$R1" == "$R2" ]] && die "Input file R1 is the same as R2 ($R1)"
bam_unsorted="$outdir"/"$sample_id"_unsorted.bam
bam_sorted="$outdir"/"$sample_id".bam
flagstat_file="$outdir"/flagstat/"$sample_id".flagstat

# Logging files and dirs
readonly LOG_DIR="$outdir"/logs
readonly VERSION_FILE="$LOG_DIR"/version.txt
readonly CONDA_YML="$LOG_DIR"/conda_env.yml
readonly ENV_FILE="$LOG_DIR"/env.txt
mkdir -p "$LOG_DIR"

# Load software and set nr of threads
load_env "$MODULE" "$CONDA" "$CONDA_YML"
set_threads "$IS_SLURM"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options/arguments passed to this script:  $all_args"
echo "Input R1 FASTQ file:                          $R1"
echo "Input R2 FASTQ file:                          $R2"
echo "Reference FASTA file:                         $ref"
echo "Output BAM file:                              $bam_sorted"
[[ -n $more_args ]] && echo "Additional arguments for $TOOL_NAME:          $more_args"
log_time "Listing the input file(s):"
ls -lh "$R1" "$R2" "$ref" 
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Make output dirs
mkdir -p "$outdir"/flagstat

# Run the BBmap
runstats $TOOL_BINARY \
    ref="$ref" \
    in1="$R1" \
    in2="$R2" \
    out="$bam_unsorted" \
    threads="$threads" \
    $SETTINGS \
    $more_args

# Run samtools
log_time "Sorting the BAM file with samtools sort..."
samtools sort "$bam_unsorted" > "$bam_sorted"
[[ "$rm_unsorted" == true ]] && rm -v "$bam_unsorted"

# Getting statistics with samtools flagstats
log_time "Getting mapping stats with Samtools flagstat:"
samtools flagstat "$bam_sorted" > "$flagstat_file"
log_time "Number of mapped reads:"
grep "primary mapped" "$flagstat_file"
grep "properly paired" "$flagstat_file" 

# List the output, report version, etc
log_time "Listing the output BAM file:"
ls -lh "$bam_sorted"
final_reporting "$VERSION_COMMAND" "$VERSION_FILE" "$ENV_FILE" "$IS_SLURM" \
    "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL"
