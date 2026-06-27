#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --gpus-per-node=2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=FAIL
#SBATCH --job-name=dorado
#SBATCH --output=slurm-dorado-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Basecall ONT reads (FAST5 or POD5) with Dorado using GPUs and output FASTQ or BAM files"
SCRIPT_VERSION="2026-04-16"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="/fs/ess/PAS0471/software/dorado/dorado-1.3.1-linux-x64/bin/dorado"
TOOL_NAME=Dorado
TOOL_DOCS=https://github.com/nanoporetech/dorado
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
version_only=false                 # When true, just print tool & script version info and exit
env_type=NA                        # No conda or container, Dorado is run from a specific path
                                   # Including this so the `final_reporting` function does not error out

# Defaults - tool parameters
model=sup                          # Basecalling model: fast, hac, or sup -- can be fast@<version> to specify kit
out_format=fastq                   # Output file format: 'fastq' or 'bam'
trim=all                           # What to trim from the reads. This is also the Dorado default. Options: 'adapters', 'none', 'all'
out_format_opt="--emit-fastq"      # (This option will be updated automatically based on out_format)

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
      sbatch $0 -i data/pod5 -o results/dorado
    
REQUIRED OPTIONS:
-i/--input          <file>  Input file or dir;
                            files should be in FAST5 or POD5 format.
                            When using FAST5, the base-calling model
                            (--model) must include the kit.
-o/--outdir         <dir>   Output dir (will be created if needed)
                            Regardless of the number of input files,
                            the output will be a single file:
                            - In case of a single input file, the output file
                              will have the same name as the input file
                            - In case of multiple input files, the output file
                              will have the same name as the input dir

OTHER KEY OPTIONS:
--model             <str>   Basecall model                                      [default: $model]
--trim              <str>   Trim adapters, options: 'adapters',
                            'none', 'all'  (= adapters + primers + barcodes)    [default: $trim]
--out_format        <str>   Output file format, 'bam' or 'fastq'                [default: $out_format]

OTHER KEY OPTIONS:
  --more_opts       <str>   Quoted string with one or more additional options
                            for $TOOL_NAME
    
UTILITY OPTIONS:
  -h/--help                 Print this help message
  -v/--version              Print script and $TOOL_NAME versions
    
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
input=
outdir=
more_opts=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --input )      shift && input=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --model )           shift && model=$1 ;;
        --trim )            shift && trim=$1 ;;
        --out_format )      shift && out_format=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
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
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$input" ]] && die "No input file/dir specified, do so with -i/--input" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$input" && ! -d "$input" ]] && die "Input file/dir $input does not exist"
[[ "$out_format" != "bam" && "$out_format" != "fastq" ]] && die "Output format should be 'fastq' or 'bam', not $out_format"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
[[ "$out_format" == "bam" ]] && out_format_opt=
[[ -f "$input" ]] && outfile="$outdir"/$(basename "${input%.*}").$out_format
[[ -d "$input" ]] && outfile="$outdir"/$(basename "$input").$out_format

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file or dir:                        $input"
echo "Output file:                              $outfile"
echo "Output format:                            $out_format"
echo "Base-calling model:                       $model"
echo "Trimming option:                          $trim"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$input"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY basecaller \
    $out_format_opt \
    $more_opts \
    $model \
    --trim "$trim" \
    $input \
    > "$outfile"

# Dorado options
#? -x, --device // device string in format "cuda:0,...,N", "cuda:all", "metal", "cpu" etc.. [default: "cuda:all"]

if [[ "$out_format" == "fastq" ]]; then
    log_time "Zipping up the output FASTQ file..."
    runstats gzip -f "$outfile"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing the output file:"
ls -lh "$outfile".gz
final_reporting "$LOG_DIR" "$env_type"
