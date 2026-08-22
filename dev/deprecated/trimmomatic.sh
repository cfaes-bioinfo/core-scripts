#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=trimmomatic
#SBATCH --output=slurm-trimmomatic-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
readonly DESCRIPTION="Run Trimmomatic to quality- and adapter-trim paired-end FASTQ files"
readonly MODULE=miniconda3/4.12.0-py39
readonly CONDA=/fs/ess/PAS0471/jelmer/conda/trimmomatic-0.39
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
readonly TOOL_BINARY=trimmomatic
readonly TOOL_NAME=Trimmomatic
readonly TOOL_DOCS="http://www.usadellab.org/cms/?page=trimmomatic"
readonly VERSION_COMMAND="$TOOL_BINARY -version"

# Constants - parameters
RUN_MODE=PE             # Script currently only works for paired-end reads

# Parameter defaults
# By default, this script will use the adapter file in mcic-scripts/misc/adapters.fa
trim_param="LEADING:3 TRAILING:3 SLIDINGWINDOW:4:15 MINLEN:36"
#? Same as example on https://github.com/usadellab/Trimmomatic and https://rpubs.com/ednachiang/MetaG_Pipeline
#? Alternatively, example of a much stricter mode: "AVGQUAL:28 LEADING:20 TRAILING:20 MINLEN:36"
adapter_param="2:30:10:2:True"
#? Same as example on https://github.com/usadellab/Trimmomatic

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
    echo "      sbatch $0 -i TODO -o results/TODO" #TODO
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile     <file>  Input file"
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
R1=
outdir=
adapter_file=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && readonly R1=$1 ;;
        -o | --outdir )     shift && readonly outdir=$1 ;;
        --adapter_file )    shift && adapter_file=$1 ;;
        --adapter_param )   shift && adapter_param=$1 ;;
        --trim_param )      shift && trim_param=$1 ;;
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
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -f "$R1" ]] && die "Input file $R1 does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Process parameters
file_ext=$(basename "$R1" | sed -E 's/.*(.fastq.gz|.fq.gz)$/\1/')
R1_suffix=$(basename "$R1" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
R2_suffix=${R1_suffix/1/2}
R2=${R1/$R1_suffix/$R2_suffix}
sample_id=$(basename "$R1" "$file_ext" | sed -E "s/${R1_suffix}_?[[:digit:]]*//")
R1_basename=$(basename "$R1" "$file_ext")
R2_basename=$(basename "$R2" "$file_ext")

# Define output files
discard_dir="$outdir"/discard                               # Dir for discarded sequences
trimstats_file="$outdir"/logs/"$sample_id".trimstats.txt    # File with Trimmomatic stdout
R1_out="$outdir"/"$R1_basename".fastq.gz                    # Output R1 FASTQ file
R2_out="$outdir"/"$R2_basename".fastq.gz                    # Output R2 FASTQ file
R1_discard=$discard_dir/"$R1_basename"_U1.fastq.gz          # Output file for discarded R1 reads
R2_discard=$discard_dir/"$R2_basename"_U2.fastq.gz          # Output file for discarded R2 reads

# Adapter parameters argument - As in the example here https://github.com/usadellab/Trimmomatic
[[ -z $adapter_file ]] && adapter_file="$script_dir"/adapters.fa
adapter_arg=" ILLUMINACLIP:$adapter_file:$adapter_param"
trim_arg=" $trim_param"

# Check input, part II
[[ ! -f "$adapter_file" ]] && die "Adapter file ($adapter_file) does not exist"
[[ ! -f $R2 ]] && die "Input file R2 ($R2) does not exist"
[[ "$R1" == "$R2" ]] && die "Input R1 and R2 FASTQ files are the same file: $R1"
[[ "$R1" == "$R1_out" ]] && die "Input R1 and output R1 FASTQ files are the same file: $R1"
[[ "$R2" == "$R2_out" ]] && die "Input R2 and output R2 FASTQ files are the same file: $R2"

# Logging files and dirs
readonly LOG_DIR="$outdir"/logs
readonly VERSION_FILE="$LOG_DIR"/version.txt
readonly CONDA_YML="$LOG_DIR"/conda_env.yml
readonly ENV_FILE="$LOG_DIR"/env.txt
mkdir -p "$LOG_DIR" "$discard_dir"

# Load software and set nr of threads
load_env "$MODULE" "$CONDA" "$CONDA_YML"
set_threads "$IS_SLURM"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options/arguments passed to this script:  $all_args"
echo "Input R1 file:                                $R1"
echo "Input R2 file:                                $R2"
echo "Output R1 file:                               $R1_out"
echo "Output R2 file:                               $R2_out"
echo "Trimming argument:                           $trim_arg"
[[ -n "$adapter_arg" ]] && echo "Adapter argument:                            $adapter_arg"
[[ -n $more_args ]] && echo "Additional arguments for $TOOL_NAME:          $more_args"
log_time "Listing the input file(s):"
ls -lh "$R1" "$R2"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Run the tool
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY $RUN_MODE \
    -threads "$threads" \
    "$R1" "$R2" \
    "$R1_out" "$R1_discard" \
    "$R2_out" "$R2_discard"${adapter_arg}${trim_arg}${more_args} \
    2>&1 | tee "$trimstats_file"

# Count the number of reads
log_time "Now counting the number of reads in the in- and output..."
nreads_raw=$(zcat "$R1" | awk '{s++} END{print s/4}')
nreads_trim=$(zcat "$R1_out" | awk '{s++} END{print s/4}')
log_time "Number of raw / trimmed read-pairs: $nreads_raw / $nreads_trim"

# List the output, report version, etc
log_time "Listing the output FASTQ files:"
ls -lh "$R1" "$R2"
final_reporting "$VERSION_COMMAND" "$VERSION_FILE" "$ENV_FILE" "$IS_SLURM" \
    "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL"
