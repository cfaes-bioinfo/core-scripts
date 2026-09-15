#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=8:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=ksnp3
#SBATCH --output=slurm-ksnp3-%j.out

#TODO - Update to KSNP4: https://sourceforge.net/projects/ksnp/files/

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run kSNP3 to identity SNPs among a set of bacterial genomes,
and to build a phylogenetic tree with these SNPs.
The script will run kSNP3 with the following hardcoded options:
  -vcf      To also output a VCF file
  -ML       To also create an ML tree
  -core     To also output files for 'core SNPs' only"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=kSNP3
TOOL_NAME=kSNP3
TOOL_DOCS="https://sourceforge.net/projects/ksnp/files/kSNP3.1.2%20User%20Guide%20.pdf/download"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/knsp-3.1
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true
version_only=false

# Contants - tool parameters
VCF_OPT="-vcf"                      # Also output a VCF file
ML_OPT="-ML"                        # Also output an ML tree
CORE_OPT="-core"                    # Also output a separate set of files for core SNPs (i.e., those shared across all genomes)

# Defaults - tool parameters
kmer_size="auto"

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i ksnp_infile.txt -o results/ksnp3"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input file which should contain one row per genome and two columns:"
    echo "                                - The first column has the ABSOLUTE (!) path to a genome FASTA"
    echo "                                - The second column has an ID for that genome"
    echo "                              E.g., a file for two genomes could look like this:"
    echo "                                  results/spades/sampleA/contigs.fasta sampleA"
    echo "                                  results/spades/sampleB/contigs.fasta sampleB"
    echo "                              NOTE: The input FASTA file names cannot contains spaces, more than one period, or special chars"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  -k                  <int>   K-mer size (odd integer)            [default: automatically determined]"
    echo "                                If you don't provide a k-mer size, the script will automatically"
    echo "                                determine one using the kSNP3 utility Kchooser"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
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
    echo "  --no_strict                 Don't use strict Bash settings ('set -euo pipefail') -- can be useful for troubleshooting"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
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
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
infile=
outdir=
opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --kmer )            shift && kmer_size=$1 ;;
        --opts )            shift && opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --no_strict )       strict_bash=false ;;
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
[[ "$strict_bash" == true ]] && set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
infile=$(realpath "$infile")
[[ ! $outdir =~ ^/ ]] && outdir="$PWD"/"$outdir"
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input file:                               $infile"
echo "Output dir:                               $outdir"
echo "Kmer size:                                $kmer_size"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Move into the output dir because kSNP3 will dump files into the working dir
log_time "Moving into output dir $outdir..."
cd "$outdir" || exit 1

# Determine the kmer-size
if [[ "$kmer_size" == "auto" ]]; then
    log_time "Picking a kmer size..."
    
    # Create combined FASTA file
    log_time "Creating a merged FASTA file for Kchooser..."
    runstats MakeFasta "$infile" "$outdir"/merged_fa_for_kchooser.fa
    
    # Run Kchooser
    log_time "Running Kchooser to pick a kmer size..."
    runstats Kchooser "$outdir"/merged_fa_for_kchooser.fa
    
    # Get the optimal kmer size from the Kchooser report
    if grep -q "The optimum value of K is" Kchooser.report; then
        kmer_size=$(grep "The optimum value of K is" Kchooser.report | sed -E 's/.*is ([0-9]+)./\1/')
    else
        die "No optimum K-value found in Kchooser.report" >&2
    fi
    
    log_time "The optimal kmer size is:         $kmer_size"

    # A kmer size of 31 probably means Kchooser needs to be rerun
    kmer_message="The optimal kmer-size is 31, which is probably incorrect
        See the kSNP3 documentation to rerun Kchooser with a different fraction of unique kmers"
    [[ "$kmer_size" == 31 ]] && die "$kmer_message" 
fi

# Run kSNP3
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -in "$infile" \
    -outdir "$outdir" \
    -k "$kmer_size" \
    $VCF_OPT \
    $ML_OPT \
    $CORE_OPT \
    -CPU "$SLURM_CPUS_PER_TASK" \
    $opts

# Report & finalize
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
