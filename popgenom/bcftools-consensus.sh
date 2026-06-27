#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=5
#SBATCH --mem=20G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bcftools-consensus
#SBATCH --output=slurm-bcftools-consensus-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Filter a VCF and then produce a per-region consensus FASTA sequence with bcftools.
Assumes that the VCF only contains a single sample. The VCF is filtered in three steps:
1) Low-quality genotypes are soft-filtered to missing (./.) based on a user-provided expression
2) SNPs within a user-defined distance of indels are filtered out (set to reference bases)
3) Indels are removed
The resulting filtered VCF is then used to generate the consensus sequence(s) with bcftools consensus.
Genotypes that were set to missing in the first step will be set to N in the consensus sequence.
Heterozygous sites will be represented with IUPAC codes.
"
SCRIPT_VERSION="2026-05-11"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=
TOOL_NAME=bcftools
TOOL_DOCS=https://samtools.github.io/bcftools/bcftools.html
VERSION_COMMAND="$TOOL_BINARY bcftools --version; $TOOL_BINARY samtools --version; $TOOL_BINARY bedtools --version"

# Defaults - generics
env_type=conda                                 # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/bcftools  # Must also contain samtools, bedtools, and seqkit
container_url=
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
filter_expr='FORMAT/DP < 5 || FORMAT/GQ < 20'  # Filter expression
snp_gap=5                                      # Minimum distance of SNPs to indels (bp)

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
      sbatch $0 -i results/my.vcf --sample_id my_sample --bed my.bed --ref data/ref.fa -o results/consensus
    
REQUIRED OPTIONS:
  -i/--vcf            <file>  Input VCF file
  --sample_id         <str>   Sample ID to use in output file names
  --ref               <file>  Input reference FASTA file
  --bed               <file>  Input BED file with regions to include in the consensus sequence
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --filter_expr       <str>   Expression to filter genotypes with, e.g.:        [default: $filter_expr]
                                'FORMAT/DP < 5 || FORMAT/GQ < 20'
                                Genotypes matching this expression are set to
                                missing (./.) in the output VCF, and thus to 'N' 
                                in the consensus sequence.
  --snp_gap           <int>   Minimum distance of SNPs to indels (bp)           [default: $snp_gap]
                                SNPs within this distance of an indel will be
                                filtered out and set to reference bases.
  --more_opts         <str>   Quoted string with one or more additional options
                                for $TOOL_NAME
    
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
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -f "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -f "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script_name"
        fi
        source "$function_script_name"
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
vcf=
ref_fa=
outdir=
bed=
sample_id=
more_opts=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --vcf )        shift && vcf=$1 ;;
        --ref )             shift && ref_fa=$1 ;;
        --bed )             shift && bed=$1 ;;
        --sample_id )       shift && sample_id=$1 ;;
        --snp_gap )         shift && snp_gap=$1 ;;
        --filter_expr )     shift && filter_expr=$1 ;;
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
indir=$(dirname "$vcf")
[[ -z "$vcf" ]] && die "No input file specified, do so with -i/--vcf" "$all_opts"
[[ -z "$ref_fa" ]] && die "No reference FASTA file specified, do so with --ref_fa" "$all_opts"
[[ -z "$bed" ]] && die "No BED file specified, do so with --bed" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$sample_id" ]] && die "No sample ID specified, do so with --sample_id" "$all_opts"
[[ ! -f "$vcf" ]] && die "Input file $vcf does not exist"
[[ ! -f "$ref_fa" ]] && die "Reference FASTA file $ref_fa does not exist"
[[ ! -f "$bed" ]] && die "BED file $bed does not exist"
[[ "$indir" == "$outdir" ]] && die "Input and output directories must be different"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
mkdir -p "$outdir"/fa "$outdir"/vcf "$outdir"/stats
vcf_out="$outdir"/vcf/"$sample_id".vcf.gz
fasta="$outdir"/fa/"$sample_id".fasta
region_counts_file="$outdir"/stats/"${sample_id}"_snp-counts-per-region.tsv
regions_file="$outdir"/stats/"$sample_id"_regions.txt

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input VCF file:                           $vcf"
echo "Input reference FASTA file:               $ref_fa"
echo "Input BED file:                           $bed"
echo
echo "Filter expr. for low-quality genotypes:   $filter_expr"
echo "Minimum distance of SNPs to indels:       $snp_gap bp"
echo "Output dir:                               $outdir"
echo "Output filtered VCF file:                 $vcf_out"
echo "Output consensus FASTA file:              $fasta"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$vcf" "$ref_fa" "$bed"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Getting basic stats on the input VCF file
log_time "Getting basic stats on the input VCF file..."
bcftools stats "$vcf" > "$outdir"/vcf_stats.txt

# Filter the VCF
log_time "Filtering the VCF file..."
# Step 1: Soft-filter bad genotypes to missing (./.) 
# Step 2: Apply the x-bp Indel gap filter and output the final compressed VCF
#         (Doing this separately -- in the consensus step, these will be reference-bases rather than missing)
# Step 3: Normalize the VCF to split multiallelics and MNVs, and left-align indels, for the next step
# Step 4: Remove indels, keeping only SNPs
#? https://samtools.github.io/bcftools/bcftools.html#filter
runstats $TOOL_BINARY bcftools filter -e "$filter_expr" --set-GTs . "$vcf" -O u |
    runstats $TOOL_BINARY bcftools filter --SnpGap "$snp_gap" -O u |
    runstats $TOOL_BINARY bcftools norm --multiallelics -any --atomize -O u |
    runstats $TOOL_BINARY bcftools view -V indels -O z -o "$vcf_out"

echo "# Resulting file:"
ls -lh "$vcf_out"

log_time "Counting sites in the raw and filtered VCF file..."
raw_count=$(zgrep -vc "^#" "$vcf")
filt_count=$(zgrep -vc "^#" "$vcf_out")
removed=$((raw_count - filt_count))
echo "Raw / filtered VCF: $raw_count / $filt_count sites (removed: $removed)"

# Count number of variable sites in the VCF:
log_time "Counting variable sites in the filtered VCF file..."
var_count=$($TOOL_BINARY bcftools view -v snps --no-header "$vcf_out" | wc -l)
echo "Variable sites in the filtered VCF: $var_count"

# Count number of SNPs per region in the BED file (Add a column with the sample ID with awk):
runstats $TOOL_BINARY bedtools intersect -c -a "$bed" -b <(bcftools view -v snps "$vcf_out") |
    awk -v OFS='\t' -v sample="$sample_id" '{print $0, sample}' > "$region_counts_file"
echo "# Resulting file:"
ls -lh "$region_counts_file"

# Index the new VCF
log_time "Indexing the filtered VCF file..."
runstats $TOOL_BINARY bcftools index "$vcf_out"

# Create a regions-file for samtools (1-based coordinates)
log_time "Formatting BED coordinates..."
awk '{print $1":"$2+1"-"$3}' "$bed" > "$regions_file"
echo "# Resulting file:"
ls -lh "$regions_file"

# Generate consensus sequence
# 1. samtools faidx grabs the reference sequence just for the focal loci
# 2. bcftools consensus reads the >chr:start-end header, maps it to the VCF, and applies the variants/Ns
log_time "Generating consensus sequences per locus..."
runstats $TOOL_BINARY samtools faidx -r "$regions_file" "$ref_fa" |
    runstats $TOOL_BINARY bcftools consensus \
        --haplotype I --missing N "$vcf_out" \
        > "$outdir"/fa/"${sample_id}"_init.fa

#! Note: when bcftools reports 'Applied X variants', this includes the counts of
#! missing genotypes (set to 'N'), so it will be higher than the variant count above.
#? --missing 'N' => set missing genotypes to 'N' in the consensus sequence
#? --haplotype I => for heterozygous sites, use IUPAC codes

# Rename the FASTA entries from region to locus ID
# NOTE: When multiple jobs write to the same output dir, use atomic file creation
# to avoid race condition. Write to temp file first, then move it (atomic operation).
lookup_file="$outdir"/stats/lookup.tsv
lookup_tmp="$lookup_file".tmp.$$

# Create lookup file atomically (only if it doesn't exist yet)
if [[ ! -f "$lookup_file" ]]; then
    awk -v OFS="\t" '{print $1":"$2+1"-"$3, $4}' "$bed" > "$lookup_tmp"
    # Atomic move - only succeeds if file doesn't exist yet
    mv "$lookup_tmp" "$lookup_file" 2>/dev/null || true
    # If move failed (another job won the race), wait for that job's file to be ready
    while [[ ! -f "$lookup_file" ]] || [[ ! -s "$lookup_file" ]]; do
        sleep 0.1
    done
else
    # File exists, wait for it to be fully written (has content)
    while [[ ! -s "$lookup_file" ]]; do
        sleep 0.1
    done
fi

# Clean up temp file if it still exists
rm -f "$lookup_tmp" 2>/dev/null || true

seqkit replace \
    -p '^(\S+)(.*)$' \
    -r '{kv} $1' \
    -k "$lookup_file" \
    "$outdir"/fa/"${sample_id}"_init.fa > "$fasta"

rm "$outdir"/fa/"${sample_id}"_init.fa

echo -e "\n# Resulting FASTA file:"
ls -lh "$fasta"
echo -e "\n# First couple of headers of the FASTA file:"
grep -m5 ">" "$fasta"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
