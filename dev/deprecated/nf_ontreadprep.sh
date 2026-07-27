#!/bin/bash
#SBATCH --account=PAS2380
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nf_ontreadprep
#SBATCH --output=slurm-nf_ontreadprep-%j.out

# Run a Nextflow workflow to prepare ONT FAST5 reads (e.g. basecalling, QC)

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Check if this is a SLURM job
if [[ -z "$SLURM_JOB_ID" ]]; then is_slurm=false; else is_slurm=true; fi

# Constants
readonly SCRIPT_NAME=nf_ontreadprep.sh
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts

readonly TOOL_NAME=nf_ontreadprep
readonly MODULE=miniconda3/4.12.0-py39
readonly CONDA_ENV=/fs/ess/PAS0471/jelmer/conda/nextflow
readonly TOOL_BINARY=nextflow
readonly TOOL_DOCS=https://github.com/jelmerp/nf_ontreadprep

#readonly WORKFLOW_REPO=https://github.com/jelmerp/nf_ontreadprep #TODO
WORKFLOW_REPO=/fs/ess/PAS2380/assembly/jelmer/workflows/ontreadprep/main.nf
readonly OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config

# Option defaults
osc_config=mcic-scripts/nextflow/osc.config  # Will be downloaded if not present here
container_dir=/fs/ess/PAS0471/containers
profile="conda"
if [[ "$is_slurm" == true ]]; then
    PROJ=$(echo "$SLURM_JOB_ACCOUNT" | tr "[:lower:]" "[:upper:]")
    work_dir=/fs/scratch/$PROJ/$USER/$TOOL_NAME
else
    work_dir= && work_dir_arg=
fi

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo
    echo "        $0 (v. $SCRIPT_VERSION): Run $TOOL_NAME"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo "  Nextflow workflow to prepare ONT FAST5 reads (e.g. basecalling, QC)"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -i <input-file> -o <output-dir> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--fast5_dir  <dir>   Input dir with FAST5 files"
    echo "  --guppy_config  <file>  Guppy config file"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --run_id        <str>   Run ID to name output files"
    echo "  --ref_assembly  <file>  Reference genome assembly nucleotide FASTA file"
    echo "  --contig_blacklist<str> Comma-separated list of contigs to remove reads for"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo "  --more_args     <str>   Quoted string with more argument(s) for $TOOL_NAME"
    echo
    echo "NEXTFLOW-RELATED OPTIONS:"
    echo "  -profile        <str>  Profile(s) to use from config files          [default: 'conda']"
    echo "  -work-dir       <dir>  Scratch (work) dir for the workflow          [default: '/fs/scratch/<OSC-proj>/<user>/ont_readprep']"
    echo "  -c/-config      <file  Additional config file                       [default: none]"
    echo "                           - Settings in this file will override default settings"
    echo "                           - Note that the mcic-scripts OSC config file will always be included, too"
    echo "                             (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for $TOOL_NAME and exit"
    echo "  -v                      Print the version of this script and exit"
    echo "  -v/--version            Print the version of $TOOL_NAME and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -i data/fast5 --guppy_config config/dna_r10.4.1_e8.2_260bps_sup.cfg"
    echo
    echo "MAIN OUTPUT FILES:"
    echo "  - PycoQC HTML reports in the folder pycoqc "
    echo "  - A single processed gzipped FASTQ file" 
    echo
    echo "TOOL DOCUMENTATION:"
    echo "  - Docs: $TOOL_DOCS"
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

# Print the tool's version
print_version() {
    set +e
    load_tool_conda
    "$TOOL_BINARY" --version
    set -e
}

# Print the tool's help
tool_help() {
    load_tool_conda
    "$TOOL_BINARY" --help
}

# Print SLURM job resource usage info
resource_usage() {
    sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%60,Elapsed,CPUTime | grep -Ev "ba|ex"
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
# Initiate variables
run_id=
fast5_dir=
guppy_config=
ref_assembly= && ref_arg=
contig_blacklist= && contig_arg=
outdir= && outdir_arg=
extra_config_file=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --run_id )          shift && readonly run_id=$1 ;;    
        -i | --fast5_dir )  shift && readonly fast5_dir=$1 ;;
        -o | --outdir )     shift && readonly outdir=$1 ;;
        --guppy_config )    shift && guppy_config=$1 ;;
        --ref_assembly )    shift && ref_assembly=$1 ;;
        --contig_blacklist ) shift && contig_blacklist=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        -work-dir )         shift && work_dir=$1 ;;
        -profile )          shift && profile=$1 ;;
        -config )           shift && extra_config_file=$1 ;;
        --more_args )       shift && readonly more_args=$1 ;;
        -h )                script_help; exit 0 ;;
        -v | --version )         print_version; exit 0 ;;
        --help )            tool_help; exit 0;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check input
[[ -z "$run_id" ]] && die "No run ID specified, do so with --run_id" "$all_args"
[[ -z "$fast5_dir" ]] && die "No input file specified, do so with -i/--fast5_dir" "$all_args"
[[ -z "$guppy_config" ]] && die "No guppy_config file specified, do so with --guppy_config" "$all_args"
[[ ! -d "$fast5_dir" ]] && die "Input dir $fast5_dir does not exist"
[[ ! -f "$guppy_config" ]] && die "Input file $guppy_config does not exist"
[[ -n "$ref_assembly" && ! -f "$ref_assembly" ]] && die "Input file $ref_assembly does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict bash settings
set -euo pipefail

# Load software and set nr of threads
load_tool_conda

# ==============================================================================
#              DEFINE OUTPUTS AND DERIVED INPUTS, BUILD ARGS
# ==============================================================================
# Define outputs based on script parameters
readonly version_file="$outdir"/logs/version.txt
readonly log_dir="$outdir"/logs

# Build the config argument
[[ ! -f "$osc_config" ]] && osc_config="$outdir"/$(basename "$OSC_CONFIG_URL")
config_arg="-c $osc_config"
[[ -n "$extra_config_file" ]] && config_arg="$config_arg -c ${extra_config_file/,/ -c }"
[[ -n "$work_dir" ]] && work_dir_arg="-work-dir $work_dir"

# Build other args
[[ -n "$outdir" ]] && outdir_arg="--outdir $outdir"
[[ -n "$ref_assembly" ]] && ref_arg="--ref_assembly $ref_assembly"
[[ -n "$contig_blacklist" ]] && contig_arg="--contig_blacklist $contig_blacklist"

# Count the nr of input files
nfile=$(ls -1 "$fast5_dir"/*fast5 | wc -l)

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:         $all_args"
echo
echo "Run ID:                               $run_id"
echo "Input FAST5 dir ($nfile files):         $fast5_dir"
echo "Guppy config file:                    $guppy_config"
[[ -n "$ref_assembly" ]] && echo "Reference assembly file:              $ref_assembly"
[[ -n "$contig_blacklist" ]] && echo "Contig_blacklist:                     $contig_blacklist" 
[[ -n "$outdir" ]] && echo "Output dir:                           $outdir"
[[ -n "$more_args" ]] && echo "Other arguments for $TOOL_NAME:       $more_args"
echo
echo "Nextflow workflow file:               $WORKFLOW_REPO"
echo "Container dir:                        $container_dir"
echo "Config file argument:                 $config_arg"
[[ -n "$work_dir" ]] && echo "Scratch (work) dir:                   $work_dir"
[[ -n "$extra_config_file" ]] && echo "Additional config file:               $extra_config_file"
echo

# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output directories
log_time "Creating the output directories..."
mkdir -pv "$log_dir" "$container_dir"

# Download the OSC config file
if [[ ! -f "$osc_config" && ! -f osc.config ]]; then
    log_time "Downloading the OSC Nextflow config file from $OSC_CONFIG_URL..."
    wget -q -O "$osc_config" "$OSC_CONFIG_URL"
fi

# Run
echo
runstats "$TOOL_BINARY" run \
    $WORKFLOW_REPO \
    --run_id "$run_id" \
    --fast5_dir "$fast5_dir" \
    --guppy_config "$guppy_config" \
    $outdir_arg \
    $ref_arg \
    $contig_arg \
    $work_dir_arg \
    -profile "$profile" \
    -resume \
    -ansi-log false \
    $config_arg \
    $more_args

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
