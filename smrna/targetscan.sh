#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=targetscan
#SBATCH --output=slurm-targetscan-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run TargetScan for miRNA target prediction"
SCRIPT_VERSION="2026-04-13"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=
TOOL_NAME=TargetScan
TOOL_DOCS=https://www.targetscan.org/vert_80/

# Hardcode binary files
TOOL_BINARY_MAIN=/fs/ess/PAS0471/jelmer/assist/2026-03_hellman/software/targetscan/targetscan_70.pl
TOOL_BINARY_CONTEXT=/fs/ess/PAS0471/jelmer/assist/2026-03_hellman/software/targetscan/TargetScan7_context_scores/targetscan_70_context_scores.pl
TOOL_BINARY_COUNT8MERS=/fs/ess/PAS0471/jelmer/assist/2026-03_hellman/software/targetscan//TargetScan7_context_scores/targetscan_count_8mers.pl
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
#! Note: the container includes 'viennarna' because the context score script needs RNAplfold
container_url="oras://community.wave.seqera.io/library/bedtools_gffread_viennarna:0fd80bd1cfac2357"
container_dir="$HOME/containers"
container_path=

# Other hardcoded files
PARAMS=/fs/ess/PAS0471/jelmer/assist/2026-03_hellman/software/targetscan/TargetScan7_context_scores/Agarwal_2015_parameters.txt
SEED_FILE=/fs/ess/PAS0471/jelmer/assist/2026-03_hellman/software/targetscan/TargetScan7_context_scores/TA_SPS_by_seed_region.txt

# Default filtering parameters
max_score=

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
        sbatch $0 -m de_mirnas.fa -g genome.fa -a annotation.gtf -o results/targetscan
    
REQUIRED OPTIONS:
  -m/--mirna_file     <file>  Input miRNA sequences (FASTA format)
  -g/--genome_fasta   <file>  Genome FASTA file
  -a/--gtf            <file>  Annotation GTF file
  --utr_table         <file>  Precomputed TargetScan UTR table
                              (3 columns: tx_id, species_id, sequence)
                              Use 'extract_transcript_utrs.py' to generate.
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --max_score         <num>   Maximum context++ score to retain                 [default: off (no filtering)]
                              (more negative is stronger,
                              -0.2 is a common threshold)
  --species_id        <str>   Species ID to use in TargetScan tables            [default: 9999]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME
    
UTILITY OPTIONS:
  --env_type          <str>   Whether to use a Singularity container          [default: $env_type]
                              ('container') or a Conda environment ('conda')
  --container_url     <str>   URL to download a container from                [default: $container_url]
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
fa_mirna=
genome_fa=
gtf=
outdir=
utr_table=
targetscan_species_id=9999
more_opts=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -m | --mirna_file )     shift && fa_mirna=$1 ;;
        -g | --genome_fasta )   shift && genome_fa=$1 ;;
        -a | --gtf )            shift && gtf=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --utr_table )           shift && utr_table=$1 ;;
        --species_id )          shift && targetscan_species_id=$1 ;;
        --more_opts )           shift && more_opts=$1 ;;
        --env_type )            shift && env_type=$1 ;;
        --conda_path )          shift && conda_path=$1 ;;
        --container_dir )       shift && container_dir=$1 ;;
        --container_url )       shift && container_url=$1 ;;
        --container_path )      shift && container_path=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version)         version_only=true ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
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

# In container mode, run external tools through apptainer; in conda mode, run directly.
RUNTIME_PREFIX=()
if [[ "$env_type" == "container" ]]; then
    [[ -z "$container_path" ]] && die "Container mode selected but container_path is empty after load_env"
    RUNTIME_PREFIX=(apptainer exec "$container_path")
fi

# Check options provided to the script
[[ -z "$fa_mirna" ]] && die "No input miRNA file specified, do so with -m/--mirna_file" "$all_opts"
[[ -z "$genome_fa" ]] && die "No genome FASTA specified, do so with -g/--genome_fasta" "$all_opts"
[[ -z "$gtf" ]] && die "No annotation GTF specified, do so with -a/--gtf" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$utr_table" ]] && die "No precomputed UTR table specified, do so with --utr_table" "$all_opts"
[[ ! -f "$fa_mirna" ]] && die "miRNA file $fa_mirna does not exist"
[[ ! -f "$genome_fa" ]] && die "Genome FASTA $genome_fa does not exist"
[[ ! -f "$gtf" ]] && die "GTF file $gtf does not exist"
[[ ! -f "$utr_table" ]] && die "Precomputed UTR table $utr_table does not exist"
[[ ! -s "$utr_table" ]] && die "Precomputed UTR table is empty: $utr_table"

# Define outputs based on script parameters
mkdir -p "$outdir"
outdir="$(realpath "$outdir")"
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# Use absolute paths for inputs, then work from within the output directory.
fa_mirna="$(realpath "$fa_mirna")"
genome_fa="$(realpath "$genome_fa")"
gtf="$(realpath "$gtf")"
utr_table="$(realpath "$utr_table")"
cd "$outdir"

# Define main output files
out_raw=targetscan_raw.tsv
out_scored=targetscan_scored.tsv
out_filtered=targetscan_filtered.tsv

# Define other output files
fa_cds=cds.fa
txt_mirna=mirnas.txt
txt_mirna_context=mirnas.context.txt
txt_orfs=orfs.txt
ids_utr=utrs.ids
ids_orf=orfs.ids
ids_common=common.ids
out_orf_8mers=ORF_8mer_counts.txt
context_binary_custom=targetscan_70_context_scores.custom.pl

# Validate species ID consistency
bad_species=$(awk -v sid="$targetscan_species_id" 'NF >= 2 && $2 != sid {n++} END {print n+0}' "$utr_table")
[[ "$bad_species" -gt 0 ]] && die "Precomputed UTR table has rows with species IDs different from --species_id=$targetscan_species_id"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input miRNA file:                         $fa_mirna"
echo "Input genome FASTA:                       $genome_fa"
echo "Input annotation GTF:                     $gtf"
echo "Precomputed UTR table:                    $utr_table"
echo "TargetScan species ID:                    $targetscan_species_id"
echo "Output dir:                               $outdir"
echo "Environment type:                         $env_type"
[[ "$env_type" == "container" ]] && echo "Container URL:                            $container_url"
[[ "$env_type" == "conda" ]] && echo "Conda env path:                           $conda_path"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$fa_mirna" "$genome_fa" "$gtf"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources


# ==============================================================================
#                       GET UTR AND CDS SEQUENCES
# ==============================================================================
# CDS
log_time "Creating CDS FASTA from genome + GTF..."
runstats "${RUNTIME_PREFIX[@]}" gffread "$gtf" -g "$genome_fa" -x "$fa_cds"
log_time "Done creating CDS FASTA, output file:"
ls -lh "$fa_cds"
[[ ! -s "$fa_cds" ]] && die "Generated CDS FASTA is empty"


# ==============================================================================
#                CONVERT FASTA FILES TO TARGETSCAN INPUT FORMAT
# ==============================================================================
# Convert input miRNA file
log_time "Converting input miRNA file to $TOOL_NAME format..."
log_time "NOTE: Writing separate miRNA-family and mature-miRNA tables for TargetScan..."
awk -v species_id="$targetscan_species_id" '/^>/ {
    if (seq != "") {
        seq_rna = toupper(seq)
        gsub(/T/, "U", seq_rna)
        seed = substr(seq_rna, 2, 7)
        print header "\t" seed "\t" species_id > family_file
        print header "\t" species_id "\t" header "\t" seq_rna > context_file
    }
    header = substr($1, 2)
    seq = ""
    next
}
!/^>/ { seq = seq $0 }
END {
    if (seq != "") {
        seq_rna = toupper(seq)
        gsub(/T/, "U", seq_rna)
        seed = substr(seq_rna, 2, 7)
        print header "\t" seed "\t" species_id > family_file
        print header "\t" species_id "\t" header "\t" seq_rna > context_file
    }
}' family_file="$txt_mirna" context_file="$txt_mirna_context" "$fa_mirna"

log_time "Listing the converted miRNA files:"
ls -lh "$txt_mirna" "$txt_mirna_context"

# Convert input CDS file
log_time "Converting input CDS file to $TOOL_NAME format..."
awk '
/^>/ {
    if (seq != "") { print tx "\t" species_id "\t" seq }
    tx = substr($1, 2)
    split(tx, parts, " ")
    tx = parts[1]
    seq = ""
}
!/^>/ { seq = seq $0 }
END {
    if (seq != "") { print tx "\t" species_id "\t" seq }
}' species_id="$targetscan_species_id" "$fa_cds" > "$txt_orfs"

# Keep only transcript IDs present in both UTR and CDS tables:
cut -f1 "$utr_table" | sort -u > "$ids_utr"
cut -f1 "$txt_orfs" | sort -u > "$ids_orf"
comm -12 "$ids_utr" "$ids_orf" > "$ids_common"
num_common=$(wc -l < "$ids_common")
[[ "$num_common" -eq 0 ]] && die "No overlapping transcript IDs between generated UTR and CDS tables"

awk 'NR==FNR { keep[$1]=1; next } ($1 in keep)' "$ids_common" "$utr_table" > "$utr_table.common"
awk 'NR==FNR { keep[$1]=1; next } ($1 in keep)' "$ids_common" "$txt_orfs" > "$txt_orfs.common"
mv "$utr_table.common" "$utr_table"
mv "$txt_orfs.common" "$txt_orfs"

log_time "Retained transcript IDs present in both UTR and CDS: $num_common"
log_time "Listing the converted CDS/ORF file:"
ls -lh "$txt_orfs"


# ==============================================================================
#                               RUN TARGETSCAN
# ==============================================================================
# Remove old TargetScan output files if they exist, to avoid confusion
[[ -f "$out_raw" ]] && rm -f "$out_raw"
[[ -f "$out_scored" ]] && rm -f "$out_scored"

# Run TargetScan
log_time "Running $TOOL_NAME..."
runstats "${RUNTIME_PREFIX[@]}" perl $TOOL_BINARY_MAIN \
    "$txt_mirna" "$utr_table" "$out_raw"

# Get ORF 8-mer counts
log_time "Getting ORF 8-mer counts..."
runstats "${RUNTIME_PREFIX[@]}" perl $TOOL_BINARY_COUNT8MERS \
    "$txt_mirna" "$txt_orfs" > "$out_orf_8mers"
log_time "Done counting ORF 8-mers, output files:"
ls -lh "$out_orf_8mers" orfs.lengths.txt

# Create dummy UTR profile file -- the available one is for human cell lines
# touch "$outdir"/empty_UTR_profiles.txt
log_time "Copying params and seed files, and create empty UTR profile file..."
cp -v "$PARAMS" "$SEED_FILE" .
touch All_cell_lines.AIRs.txt

log_time "Preparing a context-score script configured for species ID $targetscan_species_id..."
# With the hard-coded species settings rewritten from human and the default
# vertebrate whitelist to the custom species 9999 before scoring
perl -0pe 's/\$REF_SPECIES = \d+;/\$REF_SPECIES = '"$targetscan_species_id"';/; s/\@SPECIES = qw\([^)]*\);/\@SPECIES = qw('"$targetscan_species_id"');/' \
    "$TOOL_BINARY_CONTEXT" > "$context_binary_custom"
chmod u+x "$context_binary_custom"

# Get context scores
log_time "Running $TOOL_NAME context scores..."
runstats "${RUNTIME_PREFIX[@]}" perl "$context_binary_custom" \
    "$txt_mirna_context" \
    "$utr_table" \
    "$out_raw" \
    orfs.lengths.txt \
    "$out_orf_8mers" \
    "$out_scored"

#? Required input files:
#?         miRNA_file       => mature miRNA data [not used by targetscan_70.pl]
#?         UTR_file         => aligned UTRs (same as for targetscan_70.pl)
#?         PredictedTargets => output from targetscan_70_BL_PCT.pl
#?         ORF lengths      => length of each ORF corresponding to aligned 3' UTRs 
#?         ORF 8mer counts  => number of 8mer sites in ORFs of previous file
#?         TA_SPS_FILE      => TA and SPS parameters (same as for targetscan_70_BL_PCT.pl) 
#?                             called "TA_SPS_by_seed_region.txt"
#?         CS++ parameters  => Parameters for context++ score model (Agarwal et al., 2015) 
#?                             called "Agarwal_2015_parameters.txt"
#?         UTR profiles     => Affected isoform ratios (AIRs) by 3' UTR region
#?                             called "All_cell_lines.AIRs.txt"
#? Output file:
#?         ContextScoresOutput => Lists context scores and contributions
#? For a description of input file formats, type
#?         /fs/ess/PAS0471/jelmer/assist/2026-03_hellman/software/targetscan/TargetScan7_context_scores/targetscan_70_context_scores.pl -h

# Filter the output
if [[ -n "$max_score" ]]; then
    log_time "Filtering TargetScan results with context++ score <= $max_score..."
    awk -F'\t' -v OFS='\t' -v max_score="$max_score" '
    NR==1 {
        # Scan the header to find which column is the context++ score
        for (i=1; i<=NF; i++) { if ($i == "context++ score") { score_col = i } }
        print $0 # Print the header to the new file
        next
    }
    {
        if ($score_col != "" && $score_col <= max_score) { print $0 }
    }' "$out_scored" > "$out_filtered"
    #? Not using additional Site Type filter, which would be to exclude 7mer matches
    #? using $4 != "7mer-1a"
else
    log_time "No context++ score filtering applied, retaining all results"
fi


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing the output files:"
ls -lh "$outdir"/"$out_raw" "$outdir"/"$out_scored"
[[ -n "$max_score" ]] && ls -lh "$outdir"/"$out_filtered"
log_time "Successfully completed script $SCRIPT_NAME"
