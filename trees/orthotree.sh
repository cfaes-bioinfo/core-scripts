#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=5
#SBATCH --mem=20G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=orthotree
#SBATCH --output=slurm-orthotree-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Create both a nucleotide and a protein phylogenetic tree for a gene
in a focal genome based on its Orthofinder orthogroup"
SCRIPT_VERSION="2026-03-09"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=iqtree
TOOL_NAME=IQ-TREE
VERSION_COMMAND="$TOOL_BINARY --help | head -n2"

# Defaults - generics
env_type=conda                  # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/conda/iqtree3.0.1-csvtk0.31.0-mafft7.525 # Also contains bedtools 2.31.1 
container_url=oras://community.wave.seqera.io/library/csvtk_iqtree_mafft:effa91fbc93d33df
container_dir="$HOME/containers"
container_path=

# Defaults
nboot=10000                          # Number of IQ-tree ultrafast bootstraps
mem=$SLURM_MEM_PER_NODE

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
  - Basic usage example:
      sbatch $0 -i TODO -o results/TODO
    
REQUIRED OPTIONS:
  -i/--indir          <dir>   Dir with a FASTA (.fna) and GTF (.gtf) file for each genome
  --protein_id        <str>   Protein ID of the focal gene (as found in the proteome FASTA used with Orthofinder)
  --ortho_dir         <dir>   Dir with Orthofinder output for the same set of genomes as in the --indir
  -o/--outdir         <dir>   Output dir
    
OTHER KEY OPTIONS:
  --nboot             <int>   Number of Ultrafast IQ-tree bootstraps  [default: $nboot]
    
UTILITY OPTIONS:
  --env_type          <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                              ('container') or a Conda environment ('conda') 
  --container_url     <str>   URL to download a container from                  [default (if any): $container_url]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_path    <file>  Local container image file ('.sif') to use        [default (if any): $container_path]
  --conda_path        <dir>   Full path to a Conda environment to use           [default (if any): $conda_path]
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
indir=
outdir=
protein_id=
iqtree_boot_opt=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --protein_id )      shift && protein_id=$1 ;;
        --ortho_dir )       shift && ortho_dir=$1 ;;
        --nboot )           shift && nboot=$1 ;;
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
[[ -z "$indir" ]] && die "No input file specified, do so with -i/--indir" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$ortho_dir" ]] && die "No Orthofinder output dir specified, do so with --ortho_dir" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"
[[ ! -d "$ortho_dir" ]] && die "Orthofinder output dir $ortho_dir does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
mem_gb=$((8*(mem / 1000)/10))G   # 80% of available memory in GB

# Inputs
mapfile -t genomes < <(find "$indir" -iname '*.fasta' -or -iname '*.fa' -or -iname '*.fna')
orthogroups_file="$ortho_dir"/Orthogroups/Orthogroups.tsv
[[ ! -f "$orthogroups_file" ]] && die "Orthogroups file $orthogroups_file does not exist"

# Define outputs
fna_unaln="$outdir"/fna_all/"$protein_id"_concat.fna
fna_aln="$outdir"/fna_all/"$protein_id"_aln.fna
asm_list="$outdir"/assembly_list.txt
msa="$outdir"/msa_prot.faa
root_file="$outdir"/orthofinder_root.txt

# Options
[[ "$nboot" -gt 0 ]] && iqtree_boot_opt="--ufboot $nboot"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "All options passed to this script:        $all_opts"
echo "Protein ID:                               $protein_id"
echo "Input dir with genomes:                   $indir"
echo "  Number of input genomes:                ${#genomes[@]}"
echo "Input orthofinder orthogroups file:       $orthogroups_file"
echo "Output dir:                               $outdir"
echo "Number of IQ-Tree UF bootstraps:          $nboot"
log_time "Listing the first 3 input genomes:"
ls -lh "${genomes[@]:0:3}"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                           RUN - PREP
# ==============================================================================
# Create the output dirs
mkdir -p "$outdir"/fna_each "$outdir"/fna_all "$outdir"/trees

# Get orthogroup and corresponding file
log_time "Getting the focal Orthogroup..."
OG=$(grep "$protein_id" "$orthogroups_file" | cut -f1)
ortho_tree="$ortho_dir"/Gene_Trees/"$OG"_tree.txt

# Extract the orthogroup tree root
# NOTE: Tree may be missing for very small orthogroups
if [[ -f "$ortho_tree" ]]; then
    root=$(cut -d, -f1 "$ortho_tree" | cut -d: -f1 | sed -E 's/\(+//' | sed -E 's/_([0-9])_/.\1_/')
    echo "$root" > "$root_file"
    iqtree_root_opt="-o $root"
    log_time "Protein ID: $protein_id   Orthogroup: $OG    Orthofinder root: $root"
else
    iqtree_root_opt=
    log_time "Protein ID: $protein_id   Orthogroup: $OG"
    log_time "WARNING: No tree file found for orthogroup $OG, so no root is known."
fi

# Create a table showing the number of gene copies in the focal orthogroup for each included genome
OG_file1="$outdir"/"$OG".tsv               # File with all genes in the focal OG for each genome
OG_file2="$outdir"/"$OG"_gene_nrs.tsv      # File with just the nr of genes in the focal OG in each genome

cat <(head -n1 "$orthogroups_file") <(grep "$OG" "$orthogroups_file") | \
    csvtk -t transpose |
    tail -n+2 |
    sed 's/, /\t/g' \
    > "$OG_file1"
paste <(cut -f 1 "$OG_file1") <(awk '{print NF-1}' "$OG_file1") > "$OG_file2"

n1=$(awk '$2 == 1' "$OG_file2" | wc -l)
nmult=$(awk '$2 > 1' "$OG_file2" | wc -l)
nmiss=$(awk '$2 == 0' "$OG_file2" | wc -l)
log_time "Number of genomes with 1 / >1 / 0 copies: $n1 / $nmult / $nmiss"
log_time "See files $OG_file1 and $OG_file2"

# Get the MSA file for the focal orthogroup
msa_org="$ortho_dir"/MultipleSequenceAlignments/"$OG".fa
log_time "Listing the input MSA from Orthofinder, to build a protein tree:"
ls -lh "$msa_org"

# Prep the MSA file for the focal orthogroup
log_time "Modifying the MSA IDs..."
sed -E '/>GC[AF]/s/_([0-9])_/.\1_/' "$msa_org" > "$msa"
ls -lh "$msa"

# Check that there are at least 3 sequences in the MSA
nseqs=$(grep -c "^>" "$msa")
if [[ "$nseqs" -eq 3 ]]; then
    log_time "WARNING: Only 3 sequences found in MSA ($msa) -- not using bootstrap on treefile"
    iqtree_boot_opt=
fi

# Assign the correct output tree file names
# These file names differ depending on whether bootstraps are performed
if [[ -n "$iqtree_boot_opt" ]]; then
    nuc_tree="$outdir"/trees/"$OG"_nuc.contree
    prot_tree="$outdir"/trees/"$OG"_prot.contree
else
    nuc_tree="$outdir"/trees/"$OG"_nuc.treefile
    prot_tree="$outdir"/trees/"$OG"_prot.treefile
fi

# ==============================================================================
#                           RUN - PROTEIN TREE
# ==============================================================================
# Run IQ-Tree
echo -e "\n====================================================================="
log_time "Running IQ-Tree to build a protein tree..."

if [[ "$nseqs" -lt 3 ]]; then
    log_time "WARNING: Not enough sequences in MSA ($nseqs found) -- skipping tree building..."
else
    runstats iqtree \
        -s "$msa" \
        --prefix "$outdir"/trees/"$OG"_prot \
        $iqtree_boot_opt \
        $iqtree_root_opt \
        -nt "$threads" \
        -ntmax "$threads" \
        -mem "$mem_gb" \
        -redo \
        > "$outdir"/logs/iqtree_"$OG"_prot.log

    log_time "...Done. IQtree log:"
    ls -lh "$outdir"/logs/iqtree_"$OG"_prot.log
fi

# ==============================================================================
#                           RUN - NUCLEOTIDE TREE
# ==============================================================================
echo -e "\n====================================================================="
log_time "Looping over sequences in protein MSA file to create nucleotide FASTAs..."

>"$asm_list"
grep ">" "$msa" | while read -r seq_id; do
    # Get assembly and protein IDs
    asm_id=$(echo "$seq_id" | sed -E 's/>(.*)_([A-Z]+_[0-9]+)\.?[0-9]?$/\1/'| sed -E 's/_([0-9])$/.\1/')
    protein_id=$(echo "$seq_id" | sed -E 's/>(.*)_([A-Z]+_[0-9]+\.?[0-9])?$/\2/')
    
    # Inputs
    gtf_focal="$indir"/"$asm_id".gtf
    asm_focal="$indir"/"$asm_id".fna
    
    # Outputs
    gene_fna="$outdir"/fna_each/"$asm_id"_"$protein_id".fna
    gene_gtf="$outdir"/fna_each/"$asm_id"_"$protein_id".gtf
    
    # Get the gene ID
    gene_id=$(awk '$3 == "CDS"' "$gtf_focal" | grep "$protein_id" | sed -E 's/.*gene_id "([^"]+)".*/\1/')

    # Create nucleotide FASTA
    if [[ -n "$gene_id" ]]; then
        log_time "asm_id: $asm_id  /  protein_id: $protein_id / gene_id: $gene_id"
        
        # Get line from gtf
        awk '$3 == "gene"' "$gtf_focal" | grep "$gene_id" > "$gene_gtf"

        # Extract FASTA by coords
        bedtools getfasta -fi "$asm_focal" -bed "$gene_gtf" > "$gene_fna"
        
        # Prepend assembly ID + gene ID to header
        sed -i "s/>/>${asm_id}_${protein_id} /" "$gene_fna"
        
        # Check nr of entries in the FASTA
        n_entry=$(grep -c "^>" "$gene_fna")
        [[ "$n_entry" -eq 0 ]] && echo "WARNING: FASTA $gene_fna is empty "
    else
        log_time "asm_id: $asm_id  /  protein_id: $protein_id"
        log_time "WARNING: Gene not found ($asm_id / $protein_id)"
    fi
    # Keep track of assemblies to check for duplicates
    echo "$asm_id" >> "$asm_list"
done

# Check for assemblies that are present twice
log_time "Printing assemblies with multiple copies of the focal gene (none if there's no output below):"
sort "$asm_list" | uniq -c | awk '$1 > 1' | sort -nr

# Concatenate FASTA files
log_time "Creating concatenated nucleotide FASTA $fna_unaln..." 
cat "$outdir"/fna_each/*fna > "$fna_unaln"
ls -lh "$fna_unaln"

# Align the sequences
log_time "Running MAFFT to align the nucleotide FASTA..."
runstats mafft \
        --reorder \
        --auto \
        --adjustdirection \
        --leavegappyregion \
        --thread "$threads" \
        --quiet "$fna_unaln" \
        > "$fna_aln"
# (Fix FASTA header - Remove '_R_' prefixes that MAFFT adds for rev-comp seqs:)
sed -i -E 's/^>_R_/>/' "$fna_aln"

# Create the tree
if [[ "$nseqs" -lt 3 ]]; then
    log_time "WARNING: Not enough sequences in MSA ($nseqs found) -- skipping tree building..."
else
    log_time "Running IQtree to build a nucleotide tree..."
    runstats iqtree \
        -s "$fna_aln" --prefix "$outdir"/trees/"$OG"_nuc \
        $iqtree_boot_opt -redo -nt "$threads" -ntmax "$threads" -mem "$mem_gb" \
        > "$outdir"/logs/iqtree_"$OG"_nuc.log
    log_time "...Done. IQtree log:"
    ls -lh "$outdir"/logs/iqtree_"$OG"_nuc.log
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
if [[ "$nseqs" -gt 2 ]]; then
    log_time "Listing the output trees:"
    ls -lh "$nuc_tree" "$prot_tree"
    # Root file will only be present if the orthogroup tree was found
    [[ -f "$ortho_tree" ]] && ls -lh "$root_file"
fi
final_reporting "$LOG_DIR"
