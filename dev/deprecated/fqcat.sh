#!/usr/bin/env bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --job-name=fqcat
#SBATCH --output=slurm-fqcat-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants
readonly SCRIPT_NAME=fqcat.sh
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts

# Option defaults
extension="fastq.gz"
skip_count=false

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo
    echo "        $0 (v. $SCRIPT_VERSION): Run $TOOL_NAME"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  Concatenate FASTQ files"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -o <output-dir> [ -i <input dir> | <infile1> <infile2> ... ]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir     <dir>    Input dir with FASTQ files (OR: pass files as positional args after all options)"
    echo "  -o/--outfile   <file>   Output file (its dir will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --subdir       <dir>    Subdir which may or may not be one layer removed from the indir specified by -i/--indir"
    echo "                          This can be useful if FASTQ files are inside sample-specific folders"
    echo "  --extension    <str>    Input file extension                        [default: 'fastq.gz']"
    echo "  --skip_count            Don't count nr of reads in output file (useful for very large files)"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for $TOOL_NAME and exit"
    echo "  -v                      Print the version of this script and exit"
    echo "  -v/--version            Print the version of $TOOL_NAME and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i data/fastq -o data/R1_concat.fastq.gz --extension '_R1.fastq.gz'"
    echo "  sbatch $0 -i data/fastq -o data/R2_concat.fastq.gz --extension '_R2.fastq.gz'"
    echo "  sbatch $0 -i data/fastq -o data/concat.fastq.gz --subdir 'pass'"
    echo "  sbatch $0 -o data/concat.fastq.gz data/A.fastq.gz data/B.fastq.gz data/C.fastq.gz"
    echo
}

# Exit upon error with a message
die() {
    local error_message=${1}
    local error_args=${2-none}
    log_time "$0: ERROR: $error_message" >&2
    log_time "For help, run this script with the '-h' option" >&2
    if [[ "$error_args" != "none" ]]; then
        log_time "Arguments passed to the script:" >&2
        echo "$error_args" >&2
    fi
    log_time "EXITING..." >&2
    exit 1
}

# Log messages that include the time
log_time() { echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')]" ${1-""}; }

# Print the script version
script_version() {
    echo "Run using $SCRIPT_NAME by $SCRIPT_AUTHOR, version $SCRIPT_VERSION ($SCRIPT_URL)"
}

# Print SLURM job resource usage info
resource_usage() {
    sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%60,Elapsed,CPUTime | grep -Ev "ba|ex"
}

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
declare -a infiles
indir=""
outfile=""
subdir=""

# Parse command-line args
all_args="$*"
count=0
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )          shift && indir=$1 ;;
        -o | --outfile )        shift && outfile=$1 ;;
        --subdir )              shift && subdir=$1 ;;
        --extension )           shift && extension=$1 ;;
        --skip_count )          skip_count=true ;;
        -h )                    script_help; exit 0;;
        * )                     infiles[count]=$1 && count=$(( count + 1 )) ;;
    esac
    shift
done

# Check input
if [[ $indir = "" && ${#infiles[@]} -eq 0 ]]; then
    die "Please specify input dir/files with -i or positional args" "$all_args"
fi
[[ $outfile = "" ]] && die "Please specify an output file with -o" "$all_args"
[[ $indir != "" && ! -d $indir ]] && die "Input dir $indir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check if this is a SLURM job
if [[ -z "$SLURM_JOB_ID" ]]; then is_slurm=false; else is_slurm=true; fi

# Strict bash settings
set -euo pipefail

# Determine outdir
outdir=$(dirname "$outfile")

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:         $all_args"
echo "Skip counting reads?                  $skip_count"
[[ -n "$indir" ]] && echo "Input dir:                            $indir"
[[ -n "$indir" ]] && echo "File extension:                       $extension"
[[ -n "$subdir" ]] && echo "Input subdir:                         $subdir"
echo "Output file:                          $outfile"

# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output directory
log_time "Creating the output directories..."
mkdir -p "$outdir"/logs

# Find the FASTQ files
if [[ -n "$indir" ]]; then
    log_time "Searching for FASTQ files..."
    if [[ $subdir != "" ]]; then
        mapfile -t infiles < <(find "$indir"/*/"$subdir" -name "*$extension" | sort)
    else
        mapfile -t infiles < <(find "$indir" -name "*$extension" | sort)
    fi
fi
log_time "Listing the input file(s):"
ls -lh "${infiles[@]}"

log_time "Number of FASTQ files found: ${#infiles[@]}"
[[ ${#infiles[@]} -eq 0 ]] && die "No input FASTQ files..."

# Concatenate the FASTQ files
log_time "Now concatenating the FASTQ files..."
cat "${infiles[@]}" > "$outfile"

if [[ "$skip_count" == false ]]; then
    log_time "Counting the number of sequences in the output file..."
    nseqs=$(zcat "$outfile" | awk '{l++}END{print l/4}')
    log_time "Number of sequences in output file: $nseqs"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
printf "\n======================================================================"
log_time "Versions used:"
log_time "Listing files in the output dir:"
ls -lh "$(realpath "$outfile")"
[[ "$is_slurm" = true ]] && echo && resource_usage
log_time "Done with script $SCRIPT_NAME"
echo
