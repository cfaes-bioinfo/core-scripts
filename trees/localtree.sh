#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=5
#SBATCH --mem=20G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=localtree
#SBATCH --output=slurm-localtree-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Create a local phylogenetic tree with Parsnp"
SCRIPT_VERSION="2025-10-22"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
OSC_MODULE=miniconda3/24.1.2-py310
# Need to this version of Parsnp - newer versions will complain about the small region being aligned
PARSNP_CONTAINER_PREFIX="apptainer exec /fs/ess/PAS0471/containers/keep/parsnp_1.7.4--d3c1e3879a4f7186.sif"
IQTREE_CONDA=/fs/ess/PAS0471/conda/iqtree_3.0.1
BEDTOOLS_CONDA=/fs/ess/PAS0471/conda/bedtools_2.31.1
TREE_CONDA=/fs/ess/PAS0471/jelmer/conda/r_tree
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh

# Defaults
color_column=pathovar               # Name of the metadata column to color tip labels by
tiplab_column=isolate               # Name of the metadata column with alternative tip labels
keep_all=true && curated_opt=" --curated" # Keep all genomes, i.e. use the --curated flag of Parsnp? Or remove too-divergent genomes?
nboot=10000                         # Number of IQ-tree ultrafast bootstraps

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
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/spades --ref_id UPB820 --bed my.bed -o results/localtree"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  -i/--indir          <dir>   Dir with FASTA files to align (should also contain the ref FASTA)"
    echo "  -r/--ref_id         <file>  Reference genome ID (filename without extension and dir)"
    echo "  --bed               <file>  BED file with genomic coordinates of focal region"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --nboot             <int>   Number of Ultrafast IQ-tree bootstraps  [default: $nboot]"
    echo "  --allow_filter              Allow Parsnp to remove too-divergent genomes [default: keep all genomes]"
    echo "  --root              <str>   ID of the genome to root the tree with  [default: no rerooting]"
    echo "  --meta              <file>  File with metadata to plot the tree"
    echo "  --color_column      <str>   Name of the metadata column to color tip labels by ('NULL' to ignore) [default: $color_column]"
    echo "  --tiplab_column     <str>   Name of the metadata column with alternative tip labels ('NULL' to ignore) [default: $tiplab_column]"
    echo "                                NOTE: --color_column and --tiplab_column are only used when a metadata file is provided"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
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
indir=
ref_id=
outdir=
meta= && meta_opt=
bedfile=
root= && root_opt=
boot_opt=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -r | --ref_id )     shift && ref_id=$1 ;;
        --bed )             shift && bedfile=$1 ;;
        --meta )            shift && meta=$1 ;;
        --color_column )    shift && color_column=$1 ;;
        --tiplab_column )   shift && tiplab_column=$1 ;;
        --nboot )           shift && nboot=$1 ;;
        --root )            shift && root=$1 ;;
        --allow_filter )    keep_all=false && curated_opt= ;;
        -o | --outdir )     shift && outdir=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Check options provided to the script
[[ -z "$indir" ]] && die "No input dir specified, do so with -i/--indir" "$all_opts"
[[ -z "$bedfile" ]] && die "No BED file specified, do so with --bed" "$all_opts"
[[ -z "$ref_id" ]] && die "No reference genome ID specified, do so with -r/--ref_id" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"
[[ ! -f "$bedfile" ]] && die "BED file $bedfile does not exist"
[[ -n "$meta" && ! -f "$meta" ]] && die "Metadata file $meta does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
mem_gb=$((8*(SLURM_MEM_PER_NODE / 1000)/10))G   # 80% of available memory in GB

# Inputs
mapfile -t genomes < <(find "$indir" -iname '*.fasta' -or -iname '*.fa' -or -iname '*.fna' | grep -v "$ref_id")
ref="$indir"/"$ref_id".fna
[[ ! -f "$ref" ]] && die "Input reference genome FASTA $ref does not exist"

# Outputs
locus_id=$(basename "$bedfile" .bed)
outdir_parsnp="$outdir"/parsnp
parsnp_tree_org="$outdir_parsnp"/parsnp.tree
parsnp_tree=${parsnp_tree_org/.tree/_fixnames.tree}
aln_org="$outdir_parsnp"/parsnp.aln
aln=${aln_org/.aln/_fixnames.aln}
iqtree_org="$outdir"/"$locus_id".contree
iqtree=${iqtree_org/.contree/_fixnames.contree}
if [[ "$nboot" -gt 0 ]]; then
    final_tree="$iqtree"
else
    final_tree="$parsnp_tree"
fi

# Other options
[[ "$nboot" -gt 0 ]] && boot_opt="--ufboot $nboot"
[[ -n "$root" ]] && root_opt="--root $root"
[[ -n "$meta" ]] && meta_opt="--annot $meta --color_column $color_column --tiplab_column $tiplab_column"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Output dir:                               $outdir"
echo "Reference genome FASTA:                   $ref"
echo "Input dir with genomes:                   $indir"
echo "BED file with locus coordinates:          $bedfile"
echo "Number of bootstraps:                     $nboot"
[[ -n "$meta" ]] && echo "Metadata file:                            $meta"
[[ -n "$root" ]] && echo "Tree root:                                $root"
echo "Keep all genomes?                         $keep_all"            
echo "Locus ID:                                 $locus_id"
echo "Final output tree file:                   $final_tree"
echo "Number of input genomes:                  ${#genomes[@]}"
log_time "Listing the reference FASTA file:"
ls -lh "$ref"
log_time "Listing the input genomes:"
ls -lh "${genomes[@]}"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               BEDTOOLS
# ==============================================================================
# Activate the environment with bedtools
module load "$OSC_MODULE"
conda activate "$BEDTOOLS_CONDA"

# Extract FASTA from BED file with all desired regions
log_time "Running bedtools getfasta..."
bedtools getfasta -fi "$ref" -bed "$bedfile" -fo "$outdir"/"$locus_id".fa
log_time "Showing the bedtools output FASTA file:"
ls -lh "$outdir"/"$locus_id".fa


# ==============================================================================
#                               PARSNP
# ==============================================================================
log_time "Running Parsnp..."
runstats $PARSNP_CONTAINER_PREFIX parsnp \
    --output-dir "$outdir_parsnp" \
    --reference "$outdir"/"$locus_id".fa \
    --vcf${curated_opt} \
    --threads "$threads" \
    --verbose \
    --sequences "${genomes[@]}"
#--force-overwrite \

log_time "Showing the parsnp output tree file:"
ls -lh "$parsnp_tree_org"


# ==============================================================================
#                           CREATE ALIGNMENT FILE
# ==============================================================================
# Create a multi-FASTA alignment file (https://harvest.readthedocs.io/en/latest/content/harvest/quickstart.html)
log_time "Running Harvesttool to convert to a FASTA alignment file..."
runstats $PARSNP_CONTAINER_PREFIX harvesttools \
    -i "$outdir_parsnp"/parsnp.ggr \
    -M "$aln_org"

# Fix the sample IDs in the tree, so they match the IDs in the metadata file
log_time "Fixing the sample IDs in the tree and aligment..."
sed -e 's/.fna//g' \
    -e "s/$locus_id.fa.ref/$ref_id/g" \
    -e "s/'//g" \
    "$parsnp_tree_org" > "$parsnp_tree"
sed -e 's/.fna//g' \
    -e "s/$locus_id.fa.ref/$ref_id/g" \
    -e "s/'//g" \
    "$aln_org" > "$aln"


# ==============================================================================
#                               IQTREE
# ==============================================================================
# Run IQtree to get bootstrap
if [[ "$nboot" -gt 0 ]]; then
    log_time "Now running IQ-tree..."

    conda deactivate && conda activate "$IQTREE_CONDA" 

    runstats iqtree \
        -s "$outdir_parsnp"/parsnp.aln \
        --prefix "$outdir"/"$locus_id" \
        $boot_opt \
        -nt "$threads" \
        -ntmax "$threads" \
        -mem "$mem_gb" \
        -redo \
        > "$outdir"/logs/iqtree_"$locus_id".log

    log_time "...Done. IQtree log:"
    ls -lh "$outdir"/logs/iqtree_"$locus_id".log

    log_time "Fixing the sample IDs in the IQtree tree..."
    sed -e 's/.fna//g' -e "s/$locus_id.fa.ref/$ref_id/g" -e "s/'//g" "$iqtree_org" > "$iqtree"
    final_tree="$iqtree"
fi


# ==============================================================================
#                               PLOT THE TREE
# ==============================================================================
# (Note: module purge etc is necessary or r_tree Conda env gives weird errors)
for i in $(seq "${CONDA_SHLVL}"); do conda deactivate 2>/dev/null; done
module purge && module load "$OSC_MODULE" && conda activate "$TREE_CONDA"

# Plot the tree
log_time "Plotting the tree in $final_tree..."
runstats Rscript mcic-scripts/trees/ggtree.R -i "$final_tree" $root_opt $meta_opt


# ==============================================================================
#                               WRAP UP
# ==============================================================================
# Report
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
