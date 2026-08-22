#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=10
#SBATCH --mem=170G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=qiime-classify
#SBATCH --output=slurm-qiime-classify-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Classify ASV sequences with Qiime2's feature-classifier classify-sklearn"
SCRIPT_VERSION="2025-02-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=qiime
TOOL_NAME=Qiime
TOOL_DOCS=https://docs.qiime2.org/
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/qiime2-amplicon-2024.10
container_url=
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
    echo "  - Usage example -- include the training of the classifier:"
    echo "      sbatch $0 --query_fasta ASVf.fa --ref_fasta REF.fa --ref_tax TAX.tsv -o results/qiime --prefix eukaryome"
    echo "  - Usage example -- with a pre-trained classifier:"
    echo "      sbatch $0 --query_fasta ASVf.fa --classifier classifier.qza -o results/qiime --prefix eukaryome"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  --query_fasta       <file>  Input query (ASV) FASTA file"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  --prefix            <file>  Output file prefix"
    echo
    echo "REQUIRED MUTUALLY EXCLUSIVE OPTIONS:"
    echo "  --classifier        <file>  Pre-trained classifier to use (don't specify --ref_fasta or --ref_tax)"
    echo "  --ref_fasta         <file>  Input reference FASTA file (use with --ref_tax, don't specify --classifier)"
    echo "  --ref_tax           <file>  Input reference TSV taxonomy file (use with --ref_fasta, don't specify --classifier)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --more_opts         <str>   Quoted string with additional options for"
    echo "                              the feature-classifier classify-sklearn command"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type          <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --container_path    <file>  Pre-existing Singularity container image file (.sif) to use"
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
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"
    function_script="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -f "$function_script" ]]; then
        source "$function_script"
    elif [[ ! -f "$function_script_name" ]]; then
        echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
        wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script_name"
        source "$function_script_name"
    else
        source "$function_script_name"
    fi
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
query_fasta=
ref_fasta=
ref_tax=
classifier=
prefix=
outdir=
more_opts=
threads=
container_path=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --query_fasta )     shift && query_fasta=$1 ;;
        --ref_fasta )       shift && ref_fasta=$1 ;;
        --ref_tax )         shift && ref_tax=$1 ;;
        --classifier )      shift && classifier=$1 ;;
        --prefix )          shift && prefix=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
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
load_env "$conda_path" "$container_path"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$query_fasta" ]] && die "No input query FASTA file specified, do so with --query_fasta" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$prefix" ]] && die "No output file prefix specified, do so with --prefix" "$all_opts"
[[ ! -f "$query_fasta" ]] && die "Input query FASTA file $query_fasta does not exist"

if [[ -n "$classifier" ]]; then
    [[ -n "$ref_fasta" || -n "$ref_tax" ]] && die "If classifier is provided, don't specify --ref_fasta or --ref_tax" "$all_opts"
else
    [[ -z "$ref_fasta" && -z "$ref_tax" ]] && die "No classifier, input reference FASTA, or taxonomy file specified" "$all_opts"
fi
[[ -z "$ref_fasta" && -n "$ref_tax" ]] && die "Reference taxonomy but no reference FASTA specified, do so with --ref_fasta" "$all_opts"
[[ -z "$ref_tax" && -n "$ref_fasta" ]] && die "Reference FASTA but no reference taxonomy specified, do so with --ref_tax" "$all_opts"

[[ -n "$ref_fasta" && ! -f "$ref_fasta" ]] && die "Input reference FASTA file $ref_fasta does not exist"
[[ -n "$ref_tax" && ! -f "$ref_tax" ]] && die "Input reference taxonomy file $ref_tax does not exist"
[[ -n "$classifier" && ! -f "$classifier" ]] && die "Input classifier file $classifier does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input query FASTA file:                   $query_fasta"
echo "Input reference FASTA file:               $ref_fasta"
echo "Input reference taxonomy file:            $ref_tax"
echo "Output dir:                               $outdir"
echo "Output prefix:                            $prefix"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$query_fasta"
[[ -n "$ref_fasta" ]] && ls -lh "$ref_fasta"
[[ -n "$ref_tax" ]] && ls -lh "$ref_tax"
[[ -n "$classifier" ]] && ls -lh "$classifier"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Importing the ASV sequences
log_time "Importing the ASV sequences..."
runstats $TOOL_BINARY tools import \
    --type 'FeatureData[Sequence]' \
    --input-path "$query_fasta" \
    --output-path "$outdir"/"$prefix"_query-seq.qza

# Train the classifier
if [[ -z "$classifier" ]]; then
    # Import the reference taxonomy
    log_time "Importing the reference taxonomy..."
    runstats $TOOL_BINARY tools import \
        --type 'FeatureData[Taxonomy]' \
        --input-path "$ref_tax" \
        --output-path "$outdir"/"$prefix"_ref-tax.qza

    # Import the reference sequences
    log_time "Importing the reference sequence..."
    runstats $TOOL_BINARY tools import \
        --type 'FeatureData[Sequence]' \
        --input-path "$ref_fasta" \
        --output-path "$outdir"/"$prefix"_ref-seq.qza

    # Train the classifier
    log_time "Training the classifier..."
    runstats $TOOL_BINARY feature-classifier fit-classifier-naive-bayes \
        --i-reference-reads "$outdir"/"$prefix"_ref-seq.qza \
        --i-reference-taxonomy "$outdir"/"$prefix"_ref-tax.qza \
        --o-classifier "$outdir"/"$prefix"_classifier.qza
else
    log_time "Classifier provided, skipping training..."
fi

# Run the classifier
log_time "Running the classifier..."
runstats $TOOL_BINARY feature-classifier classify-sklearn \
    --i-classifier "$outdir"/"$prefix"_classifier.qza \
    --i-reads "$outdir"/"$prefix"_query-seq.qza \
    --o-classification "$outdir"/"$prefix"_taxonomy.qza \
    --p-n-jobs "$threads" \
    $more_opts


log_time "Exporting the classification results to a TSV file..."
runstats $TOOL_BINARY tools export \
    --input-path "$outdir"/"$prefix"_taxonomy.qza \
    --output-path "$outdir"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
