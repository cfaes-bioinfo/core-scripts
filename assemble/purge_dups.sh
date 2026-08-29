#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=purge_dups
#SBATCH --output=slurm-purge_dups-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run purge_dups to remove very similar contigs (likely haplotypic variants from a genome assembly)"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=run_purge_dups.py
TOOL_NAME="purge_dups"
TOOL_DOCS=https://github.com/dfguan/purge_dups
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                       # Use a 'conda' env or a Singularity 'container'
conda_path=
container_path=
container_url=docker://quay.io/biocontainers/purge_dups:1.2.6--h577a1d6_3
dl_container=false
container_dir="$HOME/containers"
version_only=false                 # When true, just print tool & script version info and exit

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage example:"
    echo "      sbatch $0 --assembly results/flye/asm.fasta --reads data/minion/my.fastq.gz -o results/purge_dups/asm.fasta"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  --assembly          <file>  Input FASTA file with genome assembly"
    echo "  --reads             <file>  Input long-read FASTQ file"
    echo "  -o/--outfile        <dir>   Output assembly FASTA file (dir will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --config            <file>  Input config file"
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "                                (NOTE: If no default '--container_url' is listed below,"
    echo "                                 you'll have to provide one in order to run the script with a container.)"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or '--dl_container' is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
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
    function_script=$(realpath "$script_dir"/../dev/"$(basename "$FUNCTION_SCRIPT_URL")")
    # Download the function script if needed, then source it
    if [[ ! -f "$function_script" ]]; then
        echo "Can't find script with Bash functions ($function_script), downloading from GitHub..."
        function_script=$(basename "$FUNCTION_SCRIPT_URL")
        wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script"
    fi
    source "$function_script"
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
assembly=
reads=
outfile=
config=
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --assembly )        shift && assembly=$1 ;;
        --reads )           shift && reads=$1 ;;
        -o | --outfile )    shift && outfile=$1 ;;
        --config )          shift && config=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
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
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$assembly" ]] && die "No input assembly file specified, do so with --assembly" "$all_opts"
[[ -z "$reads" ]] && die "No input reads file specified, do so with --reads" "$all_opts"
[[ -z "$outfile" ]] && die "No output file specified, do so with -o/--outfile" "$all_opts"
[[ ! -f "$assembly" ]] && die "Input assembly file $assembly does not exist"
[[ ! -f "$reads" ]] && die "Input file $reads does not exist"

# Define outputs based on script parameters
[[ ! "$outfile" =~ ^/ ]] && outfile="$PWD"/"$outfile"
outdir=$(dirname "$outfile")
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
file_ext=$(basename "$assembly" | sed -E 's/.*(.fasta|.fa|.fna)$/\1/')
genome_id=$(basename "$assembly" "$file_ext")
assembly=$(realpath "$assembly")
reads=$(realpath "$reads")
if [[ "$env_type" == "container" ]]; then
    BIN_DIR=/usr/local/bin    # Where the purge_dups binaries live inside the Biocontainer
else
    BIN_DIR="$conda_path"/bin
fi

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input assembly FASTA:                     $assembly"
echo "Input long reads FASTQ:                   $reads"
echo "Output dir:                               $outdir"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$assembly" "$reads"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Move into the outdir
cd "$outdir" || exit 1

# Create a reads fofn
ls -1 "$reads" > reads.fofn

# Prepare the config file
if [[ -z "$config" ]]; then
    log_time "Now Preparing the config file..."
    config="$outdir"/config.json
    runstats $CONTAINER_PREFIX pd_config.py \
        --name "$config" \
        "$assembly" \
        reads.fofn

    # Disable the BUSCO step: the purge_dups Biocontainer doesn't include BUSCO,
    # so this step always fails with exit code 127 (BUSCO is run separately elsewhere)
    jq '.busco.skip = 1' "$config" > "$config".tmp && mv "$config".tmp "$config"
fi
log_time "Showing the contents of the config file..."
cat "$config"
echo

# Run Purge-dups
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --platform bash \
    $more_opts \
    $config \
    $BIN_DIR \
    "$genome_id"

log_time "Copying the output file:"
cp -v "$genome_id"/seqs/"$genome_id".purged.fa "$outfile"

# Check in- vs output
log_time "Number of contigs in the input file: $(grep -c ">" "$assembly")"
log_time "Number of contigs in the output file: $(grep -c ">" "$outfile")"
log_time "Stats on the input file:"
seqkit stats "$assembly"
log_time "Stats on the output file:"
seqkit stats "$outfile"

# Final reporting
log_time "Listing files in the output dir:"
ls -lh "$outfile"
final_reporting "$LOG_DIR"
