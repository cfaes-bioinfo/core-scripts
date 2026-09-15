#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=5
#SBATCH --mem=20G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=nanoplot
#SBATCH --output=slurm-nanoplot-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run NanoPlot to QC ONT/PacBio reads using sequencing summary/FASTQ/BAM input"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=NanoPlot
TOOL_NAME=NanoPlot
TOOL_DOCS=https://github.com/wdecoster/NanoPlot
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container              # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/nanoplot:1.46.2--df666265eb467952
container_dir="$HOME/containers"
container_path=

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
    - Basic usage examples:
            sbatch $0 -i sequencing_summary.txt -o results/nanoplot
            sbatch $0 -i sampleA.fastq.gz -o results/nanoplot
    
REQUIRED OPTIONS:
    -i/--infile         <file>  Input file: sequencing summary text file, FASTQ, or BAM
    -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
    --more_opts         <str>   Quoted string with one or more additional
                                options for $TOOL_NAME
    
UTILITY OPTIONS:
    --env_type          <str>   Whether to use a Singularity/Apptainer container [default: $env_type]
                                ('container') or a Conda environment ('conda') 
    --container_url     <str>   URL to download a container from                [default (if any): $container_url]
    --container_dir     <str>   Dir to download a container to                  [default: $container_dir]
    --container_path    <file>  Local container image file ('.sif') to use      [default (if any): $container_path]
    --conda_path        <dir>   Full path to a Conda environment to use         [default (if any): $conda_path]
    -h/--help                   Print this help message
    -v/--version                Print script and $TOOL_NAME versions
    
TOOL DOCUMENTATION:
    $TOOL_DOCS
"
}

# Function to source the script with Bash functions
source_function_script() {
    # NOTE: the argument is optional - some call sites pass none and rely on
    #       the IS_SLURM global instead
    local is_slurm=${1:-${IS_SLURM:-false}} candidate

    # Determine the location of this script, and based on that, the function script
    if [[ "$is_slurm" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"

    # Look for a local copy first, in order of preference, and only download as a
    # last resort: the download writes into the working dir, which many jobs share
    for candidate in "$script_dir"/../dev/"$function_script_name" \
                     "$script_dir"/../core-scripts/dev/"$function_script_name" \
                     "$function_script_name"; do
        if [[ -s "$candidate" ]]; then
            source "$candidate"
            check_functions_loaded
            return 0
        fi
    done

    # Download to a temp file, then move into place, so that concurrent jobs
    # can never source a half-written file
    echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
    tmp_script=$(mktemp "$function_script_name".XXXXXX)
    if ! wget -q "$FUNCTION_SCRIPT_URL" -O "$tmp_script"; then
        rm -f "$tmp_script"
        echo "ERROR: Failed to download $FUNCTION_SCRIPT_URL" >&2
        exit 1
    fi
    mv -f "$tmp_script" "$function_script_name"
    source "$function_script_name"
    check_functions_loaded
}

# Make sure the function script really provided the functions we rely on
check_functions_loaded() {
    if ! declare -F log_time check_val die load_env >/dev/null; then
        echo "ERROR: Sourced $function_script_name but its functions are missing" >&2
        echo "       (an outdated or truncated copy may be in the way - try deleting it)" >&2
        exit 1
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
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
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
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

# Output prefix
prefix=$(basename "${infile%%.*}")_

# Input file type
if [[ "$infile" =~ txt$ ]]; then
    filetype=seqsum
    infile_opt="--summary"
elif [[ "$infile" =~ bam$ ]]; then
    filetype=bam
    infile_opt="--bam"
elif [[ "$infile" =~ fa?s?t?q.?g?z?$ ]]; then
    filetype=fastq
    infile_opt="--fastq"
else
    die "Unknown file type for input file $infile"
fi

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "Inferred input file type:                 $filetype"
echo "Output dir:                               $outdir"
echo "Output prefix:                            $prefix"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --threads "$threads" \
    $infile_opt "$infile" \
    --outdir "$outdir" \
    --prefix "$prefix" \
    --tsv_stats \
    --info_in_report \
    --no_static \
    $more_opts

#? --no-static: No static plots. Otherwise lots of Google Chrome warnings are produced.

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
