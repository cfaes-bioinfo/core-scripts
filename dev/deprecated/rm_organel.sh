#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=2:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=rm_organel
#SBATCH --output=slurm-rm_organel-%j.out

# Remove sequences that map to specific contigs of a reference assembly
# Typically used to remove organell-derived sequences prior to assembly

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants
export PATH=$PATH:mcic-scripts/map
readonly SCRIPT_NAME=rm_organel.sh
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
readonly MODULE=miniconda3/4.12.0-py39
readonly CONDA_ENV=/fs/ess/PAS0471/jelmer/conda/seqtk
readonly CONDA_ENV2=/fs/ess/PAS0471/jelmer/conda/samtools

# Option defaults
keep_sam=false

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "       REMOVE MAPPING SEQUENCES FROM LONG-READ FASTQ FILES"
    echo "       (TYPICALLY USED TO REMOVE ORGANELLE-DERIVED SEQUENCES)"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -i <input-file> -o <output-file> -r <ref> --seqids <ids> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--fq_in   <file>     Input FASTQ file"
    echo "  -o/--fq_out  <file>     Output FASTQ file"
    echo "  -r/--ref     <file>     Reference FASTA file"
    echo "  --seqids     <str>      Comma-separated list of sequence IDs (contigs/scaffold)"
    echo "                          from the reference FASTA file that should be removed"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --keep_sam              Keep the intermediate SAM file              [default: remove]"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help               Print this help message and exit"
    echo "  -v/--version            Print this script's version and exit"
    echo
}


# Load software
load_tool_conda() {
    set +u
    module load "$MODULE" # Load the OSC Conda module
    # Deactivate any active Conda environments:
    if [[ -n "$CONDA_SHLVL" ]]; then
        for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    fi
    source activate "$CONDA_ENV" # Activate the focal environment
    set -u
}

load_samtools() {
    set +u
    module load "$MODULE" # Load the OSC Conda module
    # Deactivate any active Conda environments:
    if [[ -n "$CONDA_SHLVL" ]]; then
        for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    fi
    source activate "$CONDA_ENV2" # Activate the focal environment
    set -u
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

# Print SLURM job requested resources
slurm_resources() {
    set +u
    log_time "SLURM job information:"
    echo "Account (project):                        $SLURM_JOB_ACCOUNT"
    echo "Job ID:                                   $SLURM_JOB_ID"
    echo "Job name:                                 $SLURM_JOB_NAME"
    echo "Memory (MB per node):                     $SLURM_MEM_PER_NODE"
    echo "CPUs (per task):                          $SLURM_CPUS_PER_TASK"
    echo "Time limit:                               $SLURM_TIMELIMIT"
    echo -e "=================================================================\n"
    set -u
}

# Set the number of threads/CPUs
set_threads() {
    set +u
    if [[ "$is_slurm" == true ]]; then
        if [[ -n "$SLURM_CPUS_PER_TASK" ]]; then
            readonly threads="$SLURM_CPUS_PER_TASK"
        elif [[ -n "$SLURM_NTASKS" ]]; then
            readonly threads="$SLURM_NTASKS"
        else 
            log_time "WARNING: Can't detect nr of threads, setting to 1"
            readonly threads=1
        fi
    else
        readonly threads=1
    fi
    set -u
}

# Resource usage information for any process
runstats() {
    /usr/bin/time -f \
        "\n# Ran the command: \n%C
        \n# Run stats by /usr/bin/time:
        Time: %E   CPU: %P    Max mem: %M K    Exit status: %x \n" \
        "$@"
}

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
fq_in=""
fq_out=""
ref=""
seqids=""

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --fq_in )          shift && fq_in=$1 ;;
        -o | --fq_out )         shift && fq_out=$1 ;;
        -r | --ref )            shift && ref=$1 ;;
        --seqids )              shift && seqids=$1 ;;
        --keep_sam )            keep_sam=true ;;    
        -h | --help )           script_help; exit 0;;
        * )                     die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check input
[[ -z "$fq_in" ]] && die "Please specify an input FASTQ file with -i/--fq_in" "$all_args"
[[ -z "$fq_out" ]] && die "Please specify an output FASTQ file with -o/--fq_out" "$all_args"
[[ -z "$ref" ]] && die "Please specify a reference FASTA with -r/--ref" "$all_args"
[[ -z "$seqids" ]] && die "Please specify 1 or more sequence IDs with --seqids" "$all_args"
[[ ! -f "$fq_in" ]] && die "Input file $fq_in does not exist"
[[ ! -f "$ref" ]] && die "Input file $ref does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check if this is a SLURM job
if [[ -z "$SLURM_JOB_ID" ]]; then is_slurm=false; else is_slurm=true; fi

# Strict bash settings
set -euo pipefail

# Load software and set nr of threads
load_tool_conda
set_threads

# ==============================================================================
#              DEFINE OUTPUTS AND DERIVED INPUTS, BUILD ARGS
# ==============================================================================
# FASTQ filename parsing
outdir=$(dirname "$fq_out")
file_id=$(basename "$fq_in" .fastq.gz)

# Intermediate files
scaffold_list="$outdir"/intermed/"$file_id"_selected_scaffolds.txt
ref_organel="$outdir"/intermed/"$file_id"_selected_scaffolds.fasta
sam="$outdir"/intermed/$(basename "$ref_organel" .fasta).sam  # Determined by minimap script

# Define outputs based on script parameters
readonly version_file="$outdir"/logs/version.txt
readonly log_dir="$outdir"/logs

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Input FASTQ file:                 $fq_in"
echo "Output FASTQ file:                $fq_out"
echo "Reference FASTA file:             $ref"
echo "Scaffolds/contigs to target:      $seqids"
echo "Keep SAM file?                    $keep_sam"
echo "Number of threads/cores:          $threads"
echo
log_time "Listing the input file(s):"
ls -lh "$fq_in" "$ref"
[[ "$is_slurm" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output directories
log_time "Creating the output directories..."
mkdir -pv "$log_dir" "$outdir"/intermed

# Extract focal sequences from ref assembly
log_time "Running seqtk to extract target sequences from reference..."
echo "$seqids" | tr "," "\n" > "$scaffold_list"
seqtk subseq "$ref" "$scaffold_list" > "$ref_organel"

# Map with minimap
log_time "Running the minimap script to map reads to the target sequences..."
bash minimap.sh \
    -i "$fq_in" \
    -r "$ref_organel" \
    -o "$outdir"/intermed

# Extract unmapped reads with samtools
log_time "Running the samtools script to extract unmapped reads..."
load_samtools
samtools \
    fastq \
    -n \
    -f 4 \
    -0 "$fq_out" \
    --threads $threads \
    "$sam"


# Count reads and report
echo "======================================================================"
log_time "Counting sequences in the in- and output files..."
nseq_in=$(zcat "$fq_in" | awk '{s++} END{print s/4}')
nseq_out=$(zcat "$fq_out" | awk '{s++} END{print s/4}')
echo "Nr of input / output sequences in FASTQ files: $nseq_in  /  $nseq_out"

# Remove temporary files
[[ "$keep_sam" = false ]] && rm -v "$sam"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
printf "\n======================================================================"
log_time "Versions used:"
script_version | tee -a "$version_file" 
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
[[ "$is_slurm" = true ]] && echo && resource_usage
log_time "Done with script $SCRIPT_NAME"
echo
