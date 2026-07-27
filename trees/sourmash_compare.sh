#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=sourmash_compare
#SBATCH --output=slurm-sourmash_compare-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Sourmash Compare to compute distances among genomes and plot a dendrogram
This script will:
  (1) Create sourmash signatures from FASTA files
  (2) Rename the signature to get rid of the extension for plotting
  (3) Compare the signature with 'sourmash compare'
  (4) Plot a dendrogram and distance/similarity matrix with 'sourmash plot'"
MODULE=miniconda3
CONDA=/fs/ess/PAS0471/conda/sourmash_4.9.4
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
TOOL_BINARY="sourmash"
TOOL_NAME="Sourmash Compare"
TOOL_DOCS=https://sourmash.readthedocs.io
VERSION_COMMAND="$TOOL_BINARY --version"

# Parameter defaults
kmer_size=31
use_ani=false && ani_arg=       # By default, don't use ANI as the distance metric
out_prefix="compare"            # Output filename prefix

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
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/assemblies -o results/sourmash_compare"
    echo "  - Use ANI (Average Nucleotide Identity) as the similarity metric:"
    echo "      sbatch $0 -i results/assemblies -o results/sourmash_compare --ani"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir      <dir>   Input dir with FASTA files"
    echo "  -o/--outdir     <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --ani                   Use ANI as the similarity metric            [default: Jaccard similarity]"
    echo "  --kmer_size     <int>   Kmer size                                   [default: 31]"
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
indir=
outdir=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --kmer_size )       shift && kmer_size=$1 ;;
        --ani )             use_ani=true && ani_arg="--ani" ;;
        --more_args )       shift && more_args=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         load_env "$MODULE" "$CONDA"
                            print_version "$VERSION_COMMAND" && exit 0 ;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check arguments
[[ -z "$indir" ]] && die "No input file specified, do so with -i/--indir" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Logging files and dirs
LOG_DIR="$outdir"/logs
VERSION_FILE="$LOG_DIR"/version.txt
CONDA_YML="$LOG_DIR"/conda_env.yml
ENV_FILE="$LOG_DIR"/env.txt
mkdir -p "$LOG_DIR"

# Load software and set nr of threads
load_env "$MODULE" "$CONDA" "$CONDA_YML"
set_threads "$IS_SLURM"

# Define outputs based on script parameters
[[ "$use_ani" = true ]] && out_prefix=ani
csv_out="$outdir"/output/"$out_prefix".csv     # distance/ANI matrix in CSV format
cmp_out="$outdir"/output/"$out_prefix".cmp     # distance/ANI matrix in Python format for sourmash plotting
signature_list="$outdir"/renamed_signatures.fofn

# Create array with input FASTA files
mapfile -t fastas < <(find "$indir" -iname '*.fasta' -or -iname '*.fa' -or -iname '*.fna' -or -iname '*.fna.gz')
[[ ${#fastas[@]} -eq 0 ]] && die "No FASTA files found..."

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options/arguments passed to this script:  $all_args"
echo "Dir with input FASTA files:                   $indir"
echo "Output dir:                                   $outdir"
echo "Output file prefix:                           $out_prefix"
echo "Kmer size:                                    $kmer_size"
echo "Use ANI as the similarity metric:             $use_ani"
[[ -n $more_args ]] && echo "Additional arguments for $TOOL_NAME:          $more_args"
echo "Number of FASTA files:                        ${#fastas[@]}"
log_time "Listing the input FASTA file(s):"
for fasta in "${fastas[@]}"; do ls -lh "$fasta"; done
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Create output dirs
mkdir -p "$outdir"/signatures "$outdir"/sig_renamed "$outdir"/output "$outdir"/logs

# Create a signature for each FASTA file
log_time "Creating sourmash signatures..."
runstats $TOOL_BINARY sketch dna \
    -p k="$kmer_size" \
    --outdir "$outdir"/signatures \
    "${fastas[@]}"

# Rename signatures so they have short names
log_time "Renaming sourmash signatures..."
for sig in "$outdir"/signatures/*sig; do
    newname=$(basename "$sig" .fasta.sig | sed 's/^Spades//')
    newfile="$outdir"/sig_renamed/"$(basename "$sig")"
    $TOOL_BINARY signature rename "$sig" "$newname" -o "$newfile"
done
ls "$outdir"/sig_renamed/*sig > "$signature_list"

# Run sourmash compare
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY compare \
    -k"$kmer_size" \
    $ani_arg \
    --from-file "$signature_list" \
    --csv "$csv_out" \
    $more_args \
    -o "$cmp_out"

# Make plots - run separately for PNG and PDF output
log_time "Creating plots..."
runstats $TOOL_BINARY plot --labels --output-dir "$outdir"/output "$cmp_out"
runstats $TOOL_BINARY plot --labels --pdf --output-dir "$outdir"/output "$cmp_out"

# List the output, report version, etc
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/output/*
final_reporting "$VERSION_COMMAND" "$VERSION_FILE" "$ENV_FILE" "$IS_SLURM" \
    "$SCRIPT_NAME" "$SCRIPT_AUTHOR" "$SCRIPT_VERSION" "$SCRIPT_URL"
