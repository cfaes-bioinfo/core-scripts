#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=15
#SBATCH --gpus-per-node=2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=FAIL
#SBATCH --job-name=guppy
#SBATCH --output=slurm-guppy_gpu-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Software
readonly SCRIPT_NAME=guppy_gpu.sh
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly REPO_URL=https://github.com/mcic-osu/mcic-scripts
readonly GUPPY_DIR=/fs/ess/PAS0471/jelmer/software/guppy-6.5.7/ont-guppy
readonly TOOL_BINARY="$GUPPY_DIR"/bin/guppy_basecaller
readonly MODULE=cuda

# Hardcoded parameters
CHUNKS_PER_RUNNER=256
RECORDS_PER_FASTQ=0      # 0 => no limit

# Defaults
trim_adapters=true
trim_primers=true

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo
    echo "        $0 (v. $SCRIPT_VERSION): Run $TOOL_NAME"
    echo "        =============================================="
    echo
    echo "DESCRIPTION:"
    echo "  Perform FAST5 => FASTQ basecalling with Guppy using GPUs"
    echo 
    echo "USAGE:"
    echo "  sbatch $0 -i <input file> -o <output dir> --config <config file> [...]"
    echo "  bash $0 --help"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile     <file>  Input FAST5 file"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo "  --config        <str>   Config file name. Find the appropriate config file by:"
    echo "                            1) Running this script with option '--print_workflows' to find appropriate config name"
    echo "                            2) Running this script with option '--list_configs' to find corresponding config file"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --keep_adapters         Don't remove adapters                       [default: remove adapters]"
    echo "                          NOTE: It doesn't seem like any adapters are actually removed by Guppy either way!"
    echo "  --keep_primers          Don't remove primers                        [default: remove primers]"
    echo "  --min_qscore    <int>   Minimum quality-score                       [default: whatever is specified in the focal config file]"
    echo "  --barcode_kit   <str>   Barcode set                                 [default: none - no demultiplexing]"
    echo "  --more_args     <str>   Quoted string with additional argument(s) to pass to Guppy"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --print_workflows       List available config names by flowcell and kit ID"
    echo "  --list_configs          List available config files"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for Guppy and exit"
    echo "  -v/--version            Print the version of Guppy and exit"
    echo
    echo "HARDCODED GUPPY PARAMETERS:"
    echo "  - --chunks_per_runner=256"
    echo "  - --records_per_fastq=0"
    echo "  - --compress_fastq"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i data/minion/my.fast5 -o results/guppy --config dna_r9.4.1_450bps_sup.cfg"
    echo
    echo "This script will run Guppy for one FAST5 file, so you should loop over the FAST5 files, e.g.:"
    echo "  for fast5 in data/minion/fast5/*fast5; do"
    echo '      outdir=results/guppy/$(basename "$infile" .fast5)'
    echo '      sbatch $0 -i $fast5 -o results/guppy --config dna_r9.4.1_450bps_sup.cfg'
    echo "  done"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - https://community.nanoporetech.com/docs/prepare/library_prep_protocols/Guppy-protocol/v/gpb_2003_v1_revan_14dec2018/run-guppy-on-linux"
    echo "  - https://community.nanoporetech.com/docs/prepare/library_prep_protocols/Guppy-protocol/v/gpb_2003_v1_revan_14dec2018/setting-up-a-run-configurations-and-parameters"
    echo
}

# Print the tool's help
list_configs() {
    load_tool
    ls -1 "$GUPPY_DIR"/data/*cfg
}

print_workflows() {
    load_tool
    $TOOL_BINARY --print_workflows
}

# Load software
load_tool() {
    module load "$MODULE"
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
    echo "Run using $SCRIPT_NAME by $SCRIPT_AUTHOR, version $SCRIPT_VERSION ($REPO_URL)"
}

# Print the tool's version
print_version() {
    load_tool
    $TOOL_BINARY --version | head -1
}

# Print the tool's help
tool_help() {
    load_tool
    "$TOOL_BINARY" --help
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
infile=
outdir=
config=
min_qscore= && qscore_arg=
barcode_kit= && barcode_arg=
more_args=
adapter_arg=
primer_arg=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --config )          shift && config=$1 ;;
        --keep_adapters )   trim_adapters=false ;;
        --keep_primers )    trim_primers=false ;;
        --barcode_kit )     shift && barcode_kit=$1 ;;
        --min_qscore )      shift && min_qscore=$1 ;;
        --more_args )       shift && more_args=$1 ;;
        --print_workflows ) print_workflows; exit 0 ;;
        --list_configs )    list_configs; exit 0 ;;
        -v | -v | --version )    print_version; exit 0 ;;
        -h )                script_help; exit 0 ;;
        --help )            tool_help; exit 0;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check input
[[ -z "$infile" ]] && die "Please specify an input FAST5 file with -i/--infile" "$all_args"
[[ -z "$outdir" ]] && die "Please specify an output dir with -o/--outdir" "$all_args"
[[ -z "$config" ]] && die "Please specify an input config name with --config" "$all_args"
[[ ! -f "$infile" ]] && die "Input FAST5 file $infile does not exist"

# ==============================================================================
#                          OTHER SETUP
# ==============================================================================
# Check if this is a SLURM job
if [[ -z "$SLURM_JOB_ID" ]]; then is_slurm=false; else is_slurm=true; fi

# Bash script settings
set -euo pipefail

# Set nr of threads
set_threads

# ==============================================================================
#              DEFINE OUTPUTS AND DERIVED INPUTS, BUILD ARGS
# ==============================================================================
# Define outputs based on script parameters
readonly version_file="$outdir"/logs/version.txt
readonly log_dir="$outdir"/logs

# Build input argument
indir=$(dirname "$infile")
infile_base=$(basename "$infile")
fofn="$outdir"/tmp/"$infile_base".fofn
infile_arg="--input_file_list $fofn"

# Optional parameters
[[ -n "$barcode_kit" ]] && barcode_arg="--barcode_kits $barcode_kit --trim_barcodes"
[[ -n "$min_qscore" ]] && qscore_arg="--min_qscore $min_qscore"
[[ "$trim_adapters" == true ]] && adapter_arg="--trim_adapters"
[[ "$trim_primers" == true ]] && primer_arg="--trim_primers"


# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Input file:                       $infile"
echo "Output dir:                       $outdir"
echo "ONT config name:                  $config"
echo "Trim adapters?                    $trim_adapters"
echo "Trim primers?                     $trim_primers"
[[ $min_qscore != "" ]] && echo "Minimum qual score to PASS:       $min_qscore"
[[ $barcode_kit != "" ]] && echo "Barcode kit name:                 $barcode_kit"
[[ $more_args != "" ]] && echo "Other arguments for Guppy:        $more_args"
echo "Number of threads/cores:          $threads"
echo
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ "$is_slurm" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output directories
log_time "Creating the output directories..."
mkdir -pv "$outdir"/tmp "$log_dir"

# Create fofn
log_time "Creating the input FOFN file..."
echo "$infile_base" > "$fofn"

# Run Guppy
log_time "Running Guppy..."
runstats $TOOL_BINARY \
    --input_path "$indir" \
    $infile_arg \
    --save_path "$outdir" \
    --config "$config" \
    --compress_fastq \
    --records_per_fastq "$RECORDS_PER_FASTQ" \
    --gpu_runners_per_device "$threads" \
    --as_gpu_runners_per_device "$threads" \
    --chunks_per_runner "$CHUNKS_PER_RUNNER" \
    --num_callers "$threads" \
    --device "cuda:0" \
    $adapter_arg \
    $primer_arg \
    $qscore_arg \
    $barcode_arg \
    $more_args

#? GPU parameters
# - https://github.com/colindaven/guppy_on_slurm/blob/master/runbatch_gpu_guppy.sh
#   gpu_params='--device "cuda:0" --num_callers 4 --gpu_runners_per_device 4 --chunks_per_runner 512 --chunk_size 3000'
# - See "Tuning GPU parameters for Guppy performance" https://hackmd.io/@Miles/S12SKP115

#? To print config names for flowcell + kit combs:
#$ guppy_basecaller --print_workflows
# - For kit LSK109 and flowcell FLO-MIN106:         dna_r9.4.1_450bps_hac
# - For kit SQK-LSK114 and flowcell FLO-MIN114:     dna_r10.4.1_e8.2_260bps_hac
# - See also the available config files in /fs/ess/PAS0471/jelmer/software/guppy-6.4.2/data/

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
printf "\n======================================================================"
log_time "Versions used:"
print_version | tee "$version_file"
script_version | tee -a "$version_file" 
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
[[ "$is_slurm" = true ]] && echo && resource_usage
log_time "Done with script $SCRIPT_NAME"
echo
