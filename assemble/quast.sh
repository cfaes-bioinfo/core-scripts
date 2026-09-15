#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=20
#SBATCH --mem=80G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=quast
#SBATCH --output=slurm-quast-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run QUAST to check the quality of one or more genome assemblies"
SCRIPT_VERSION="2026-05-21"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=quast.py
TOOL_NAME=Quast
TOOL_DOCS="https://github.com/ablab/quast / https://quast.sourceforge.net/docs/manual.html"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container
conda_path=
container_dir="$HOME/containers"
container_url=oras://community.wave.seqera.io/library/quast:5.3.0--bfd4c029fde7e696
container_path=

# Defaults - tool parameters
is_fragmented=false && is_fragmented_opt=
is_large=false && is_large_opt=
kmer_stats=false && kmer_stats_opt=
run_busco=false && busco_opt=

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
  - Usage examples:
    sbatch $0 --assembly results/assembly/my.fasta -o results/quast
    sbatch $0 --assembly_dir results/assemblies -o results/quast
    sbatch $0 -o results/quast results/racon/assembly.fasta results/smartdenovo/assembly.fasta
    sbatch $0 --assembly_dir results/assemblies -o results/quast --more_opts '--eukaryote'
    
REQUIRED OPTIONS:
  -o/--outdir         <dir>   Output dir (will be created if needed)

  To specify the input assembly/assemblies, use ONE of the following options:
  -i/--assembly      <file>  Input assembly FASTA file
  --assembly_dir     <dir>   Input dir with assembly FASTA files (extension '.fasta')
  ...Pass assembly FASTA files(s) as positional arguments at the end of the command.
    
OTHER KEY OPTIONS:
  --ref_fa            <file>  Reference genome nucleotide FASTA file
  --ref_annot         <file>  Reference genome annotation (GFF/GTF) file
  --R1                <file>  FASTQ file with forward (R1) Illumina reads
                              (The R2 filename will be inferred)
  --reads             <file>  FASTQ file with single-end Illumina reads
  --fragmented                QUAST's '--fragmented' option,
                                use for fragmented assemblies
  --large                     QUAST's '--large' option,
                                recommended for genomes >100 Mbp
  --kmer_stats                QUAST's '--k-mer-stats' option,
                                recommended for genomes >100 Mbp
  --run_busco                 Use this flag to run BUSCO within QUAST
                              BUSCO is not run by default, because at least for
                              eukaryotes it fails to download the database.
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME.
    
UTILITY OPTIONS:
  --env_type          <str>   Use a Singularity container ('container')         [default: $env_type]
                              or a Conda environment ('conda') 
  --conda_path        <dir>   Full path to a Conda environment to use           [default: $conda_path]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_url     <str>   URL to download a container from                  [default (if any): $container_url]
  --container_path    <file>  Local singularity image file (.sif) to use        [default (if any): $container_path]
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
outdir=
infile=
assembly_dir=
declare -a assemblies
R1=
R2=
ref_fa= && ref_fa_opt=
ref_annot= && ref_annot_opt=
reads= && illumina_reads_opt=
nanopore= && nanopore_opt=
busco_opt=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --assembly )   shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --assembly_dir )    shift && assembly_dir=$1 ;;
        --ref_fa )          shift && ref_fa=$1 ;;
        --ref_annot )       shift && ref_annot=$1 ;;
        --R1 )              shift && R1=$1 ;;
        --reads )           shift && reads=$1 ;;
        --nanopore )        shift && nanopore=$1 ;;
        --fragmented )      is_fragmented=true ;;
        --large )           is_large=true ;;
        --kmer_stats )      kmer_stats=true ;;
        --run_busco )       run_busco=true ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --conda_path )      shift && conda_path=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
        --container_path )  shift && container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
        * )                 assemblies+=("$1") ;;
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
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

# Build argument for assembly input
if [[ -n $assembly_dir ]]; then
    mapfile -t assemblies < <(find "$assembly_dir" -name "*.fasta")
elif [[ -n $infile ]]; then
    assemblies=("$infile")
elif [[ ${#assemblies[@]} -eq 0 ]]; then
    die "Please specify input with --assembly_dir, --assembly, or positional arguments" "$all_opts"
fi

# Verify assembly files exist
for asm in "${assemblies[@]}"; do
    [[ ! -f "$asm" ]] && die "Assembly file $asm does not exist"
done

# If the input is a single file, make a separate output dir
if [[ ${#assemblies[@]} -eq 1 ]]; then
    sampleID=$(basename "${assemblies[0]}" | sed -E 's/.fn?as?t?a?//')
    outdir=$outdir/"$sampleID"
fi

# Build input reads arg(s)
if [[ -n $R1 ]]; then
    file_ext=$(basename "$R1" | sed -E 's/.*(.fastq.gz|.fq.gz)$/\1/')
    R1_suffix=$(basename "$R1" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
    R2_suffix=${R1_suffix/1/2}
    R2=${R1/$R1_suffix/$R2_suffix}
    illumina_reads_opt="-1 $R1 -2 $R2"
    [[ ! -f "$R1" ]] && die "Input R1 reads file $R1 does not exist"
    [[ ! -f "$R2" ]] && die "Input R2 reads file $R2 does not exist"
    [[ "$R1" = "$R2" ]] && die "R1 and R2 FASTQ files are the same file: $R1"
elif [[ -n $reads ]]; then
    illumina_reads_opt="--single $reads"
    [[ ! -f "$reads" ]] && die "Input single-end reads file $reads does not exist"
fi

if [[ -n $nanopore ]]; then
    nanopore_opt="--nanopore $nanopore"
    [[ ! -f "$nanopore" ]] && die "Input Nanopore reads file $nanopore does not exist"
fi

# Build other arguments
[[ -n "$ref_fa" ]] && ref_fa_opt="-r $ref_fa"
[[ -n "$ref_annot" ]] && ref_annot_opt="--features $ref_annot"
[[ "$is_fragmented" == true ]] && is_fragmented_opt="--fragmented"
[[ "$is_large" == true ]] && is_large_opt="--large"
[[ "$kmer_stats" == true ]] && kmer_stats_opt="--k-mer-stats"
[[ "$run_busco" == true ]] && busco_opt="--conserved-genes-finding"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Output dir:                               $outdir"
echo "Assemblies:                               ${assemblies[*]}"
echo "Number of assemblies:                     ${#assemblies[@]}"
[[ -n $infile ]] && echo "Input assembly FASTA:                     $infile"
[[ -n $assembly_dir ]] && echo "Input dir with assemblies:                $assembly_dir"
[[ -n $ref_fa ]] && echo "Reference FASTA file:                     $ref_fa"
[[ -n $ref_annot ]] && echo "Reference annotation file:                $ref_annot"
[[ -n $R1 ]] && echo "R1 FASTQ file:                            $R1"
[[ -n $R2 ]] && echo "R2 FASTQ file:                            $R2"
[[ -n $reads ]] && echo "Single-end FASTQ file:                    $reads"
[[ -n $nanopore ]] && echo "Nanopore FASTQ file:                      $nanopore"
[[ -n $more_opts ]] && echo "Other options to pass to QUAST:           $more_opts"
echo "Fragmented assembly:                      $is_fragmented"
echo "Large assembly (>100 Mbp):                $is_large"
echo "Use kmer stats:                           $kmer_stats"
echo -e "\n# Listing the input files:"
[[ "$ref_fa" ]] && ls -lh "$ref_fa"
[[ "$ref_annot" ]] && ls -lh "$ref_annot"
[[ "$R1" ]] && ls -lh "$R1" "$R2"
[[ "$reads" ]] && ls -lh "$reads" 
[[ "$nanopore" ]] && ls -lh "$nanopore"
ls -lh "${assemblies[@]}"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --threads "$threads" \
    --output-dir "$outdir" \
    --glimmer \
    --circos \
    --no-snps \
    $busco_opt \
    $ref_fa_opt \
    $ref_annot_opt \
    $illumina_reads_opt \
    $nanopore_opt \
    $is_fragmented_opt \
    $is_large_opt \
    $kmer_stats_opt \
    $more_opts \
    "${assemblies[@]}"

#? - glimmer: Acticate gene-finding, use Glimmer instead of GeneMark tools (trouble running those due to licensing issues)
#? - conserved-genes-finding => runs Busco

#? -k  --k-mer-stats   Compute k-mer-based quality metrics (recommended for large genomes)
#?                     This may significantly increase memory and time consumption on large genomes

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
