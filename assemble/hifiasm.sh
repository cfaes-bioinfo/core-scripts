#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=48:00:00
#SBATCH --cpus-per-task=40
#SBATCH --mem=172G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=hifiasm
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Assemble a genome from PacBio HiFi reads with hifiasm, and convert the resulting GFA graphs to FASTA"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=hifiasm
TOOL_NAME=hifiasm
TOOL_DOCS="https://hifiasm.readthedocs.io | https://github.com/chhylp123/hifiasm"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/hifiasm:0.25.0--845894156e2baeba
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
purge_level=3                       # -l: purge-dups level (0=off, 1=light, 2/3=aggressive); 3 is also hifiasm's own default for HiFi-only mode
purge_simi=                         # -s: similarity threshold for duplicate haplotigs (tool default: 0.55 at -l3, 0.75 at -l1/-l2)
telo_motif=                         # --telo-m: telomere motif as seen at the 5'-end; CCCTAA = the canonical vertebrate (TTAGGG)n repeat
hg_size=                            # --hg-size: estimated haploid genome size, e.g. '500m' (tool default: inferred from the k-mer spectrum)
hom_cov=                            # --hom-cov: homozygous read coverage (tool default: inferred from the k-mer spectrum)
n_hap=2                             # --n-hap: number of haplotypes (2 = diploid)
dual_scaf=false                     # --dual-scaf: additionally scaffold each haplotype using the other one
ignore_bins=false                   # -i: ignore cached error-correction/overlap bin files from a previous run
hic_r1=                             # --h1: Hi-C R1 FASTQ file(s), comma-separated (only if Hi-C data is available)
hic_r2=                             # --h2: Hi-C R2 FASTQ file(s), comma-separated (only if Hi-C data is available)
prefix=                             # -o: output file prefix (default: derived from the input file name)

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

hifiasm caches its error-corrected reads and overlaps as '<prefix>*.bin' files in
the output dir. Rerunning with the same -o/--outdir and --prefix therefore skips
the (slowest) error-correction and overlap stages, which makes it fast to retry
with different assembly/purging settings. Use --ignore-bins to force a rerun from
scratch.

USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i data/hifi_reads.fastq.gz -o results/hifiasm
  - Give hifiasm the homozygous coverage instead of letting it infer one:
      sbatch $0 -i data/hifi_reads.fastq.gz -o results/hifiasm --hom-cov 80
  - Purge less aggressively (e.g. when the assembly came out too small):
      sbatch $0 -i data/hifi_reads.fastq.gz -o results/hifiasm --purge-level 1
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i .... -o ... --more_opts \"--primary\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input FASTQ file with PacBio HiFi reads (may be gzipped)
  -o/--outdir         <dir>   Output dir (will be created if needed)

OTHER KEY OPTIONS:
  --prefix            <str>   Output file prefix                                [default: derived from the input file name]
  --purge-level       <int>   Purge-dups level (-l): 0=off, 1=light, 2/3=aggressive [default: $purge_level]
  --purge-simi        <num>   Similarity threshold for duplicate haplotigs (-s) [default: tool default (0.55 at -l3)]
  --telo-motif/--telo-m <str> Telomere motif at the 5'-end (--telo-m)          [default: ${telo_motif:-none (disabled)}]
                              e.g. 'CCCTAA' - the vertebrate (TTAGGG)n repeat
  --no-telo                   Disable telomere identification altogether
  --hg-size           <str>   Estimated haploid genome size (--hg-size),        [default: tool infers it]
                              e.g. '500m'
  --hom-cov           <int>   Homozygous read coverage (--hom-cov)              [default: tool infers it]
  --n-hap             <int>   Number of haplotypes (--n-hap)                    [default: $n_hap]
  --dual-scaf                 Also output scaffolds, bridging gaps in each      [default: $dual_scaf]
                              haplotype with the other one (--dual-scaf)
  --ignore-bins               Ignore cached '.bin' files and rerun from scratch (-i) [default: $ignore_bins]
  --hic-r1            <str>   Comma-separated Hi-C R1 FASTQ file(s) (--h1)      [default: none]
  --hic-r2            <str>   Comma-separated Hi-C R2 FASTQ file(s) (--h2)      [default: none]
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  In HiFi-only mode, the assemblies of interest are:
    <prefix>.bp.p_ctg.gfa/.fasta      - Primary contigs (usually the main assembly)
    <prefix>.bp.hap1.p_ctg.gfa/.fasta - Partially phased haplotype 1
    <prefix>.bp.hap2.p_ctg.gfa/.fasta - Partially phased haplotype 2
  (With Hi-C data the 'bp.' infix is dropped, since the haplotypes are then fully phased.)
  This script converts every '*.p_ctg.gfa', '*.a_ctg.gfa' and '*.p_scaf.gfa' to FASTA.
  Also produced: '<prefix>.r_utg.gfa'/'<prefix>.p_utg.gfa' (unitig graphs, not
  converted), '*.lowQ.bed' (low-consistency regions), and '*.bin' (cached, see above).

  Alongside the tool's own output, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    conda_env.yml   - The Conda environment (when using Conda)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:
  --env_type          <str>   Software environment: 'conda', 'container'        [default: $env_type]
                              (Singularity/Apptainer), or 'none' (tool must
                              already be available in your PATH)
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
    local is_slurm=${1:-false}

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
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -s "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -s "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            # Download to a temp file, then move into place, so that concurrent
            # jobs can never source a half-written file
            tmp_script=$(mktemp "$function_script_name".XXXXXX)
            if ! wget -q "$FUNCTION_SCRIPT_URL" -O "$tmp_script"; then
                rm -f "$tmp_script"
                echo "ERROR: Failed to download $FUNCTION_SCRIPT_URL" >&2
                exit 1
            fi
            mv -f "$tmp_script" "$function_script_name"
        fi
        source "$function_script_name"
    fi

    # Make sure the functions were really loaded
    if ! declare -F log_time check_val >/dev/null; then
        echo "ERROR: Sourced $function_script_name but its functions are missing" >&2
        echo "       (an outdated copy may be cached - try deleting it)" >&2
        exit 1
    fi
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "${SLURM_JOB_ID:-}" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script "$IS_SLURM"

# Report clearly if this script exits with a non-zero status
trap report_on_exit EXIT

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
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --prefix )          check_val "$1" "${2:-}"; shift; prefix=$1 ;;
        --purge-level )     check_val "$1" "${2:-}"; shift; purge_level=$1 ;;
        --purge-simi )      check_val "$1" "${2:-}"; shift; purge_simi=$1 ;;
        --telo-motif | --telo-m ) check_val "$1" "${2:-}"; shift; telo_motif=$1 ;;
        --no-telo )         telo_motif= ;;
        --hg-size )         check_val "$1" "${2:-}"; shift; hg_size=$1 ;;
        --hom-cov )         check_val "$1" "${2:-}"; shift; hom_cov=$1 ;;
        --n-hap )           check_val "$1" "${2:-}"; shift; n_hap=$1 ;;
        --dual-scaf )       dual_scaf=true ;;
        --ignore-bins )     ignore_bins=true ;;
        --hic-r1 )          check_val "$1" "${2:-}"; shift; hic_r1=$1 ;;
        --hic-r2 )          check_val "$1" "${2:-}"; shift; hic_r2=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )      check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )  check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check software env
[[ -z "$TOOL_BINARY" ]] && die "TOOL_BINARY has not been set in this script"
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

# Load software
load_env   # Note: reads the env_type/conda_path/container_* globals, takes no args
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ -n "$hic_r1" && -z "$hic_r2" ]] && die "--hic-r1 was given without --hic-r2" "$all_opts"
[[ -z "$hic_r1" && -n "$hic_r2" ]] && die "--hic-r2 was given without --hic-r1" "$all_opts"

# Warn if the output dir already holds results from a previous run
# NOTE: this is only a warning - an existing outdir is in fact useful here,
#       since hifiasm will reuse its cached '.bin' files (unless --ignore-bins)
check_outdir "$outdir"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"
[[ -z "$prefix" ]] && prefix=$(basename "$infile" | sed -E 's/\.(fastq\.gz|fq\.gz|fastq|fq)$//')
out_prefix="$outdir"/"$prefix"

# Build the optional/flag-style options
telo_opt=$( [[ -n "$telo_motif" ]] && echo "--telo-m $telo_motif" || true )
dual_scaf_opt=$( [[ "$dual_scaf" == true ]] && echo "--dual-scaf" || true )
ignore_bins_opt=$( [[ "$ignore_bins" == true ]] && echo "-i" || true )
hic_opt=$( [[ -n "$hic_r1" ]] && echo "--h1 $hic_r1 --h2 $hic_r2" || true )

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "Output dir:                               $outdir"
echo "Output file prefix:                       $prefix"
echo "Purge-dups level (-l):                    $purge_level"
[[ -n $purge_simi ]] && echo "Purge similarity threshold (-s):          $purge_simi"
echo "Number of haplotypes (--n-hap):           $n_hap"
echo "Telomere motif (--telo-m):                ${telo_motif:-<disabled>}"
echo "Haploid genome size (--hg-size):          ${hg_size:-<tool infers it>}"
echo "Homozygous coverage (--hom-cov):          ${hom_cov:-<tool infers it>}"
echo "Also output scaffolds (--dual-scaf):      $dual_scaf"
echo "Ignore cached '.bin' files (-i):          $ignore_bins"
[[ -n $hic_r1 ]] && echo "Hi-C R1 file(s) (--h1):                   $hic_r1"
[[ -n $hic_r2 ]] && echo "Hi-C R2 file(s) (--h2):                   $hic_r2"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file:"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    -o "$(printf '%q' "$out_prefix")" \
    -t "$threads" \
    -l "$purge_level" \
    --n-hap "$n_hap" \
    ${purge_simi:+-s "$purge_simi"} \
    ${hg_size:+--hg-size "$hg_size"} \
    ${hom_cov:+--hom-cov "$hom_cov"} \
    $telo_opt \
    $dual_scaf_opt \
    $ignore_bins_opt \
    $hic_opt \
    $more_opts \
    "$(printf '%q' "$infile")"

# Report the coverage that hifiasm settled on - if this is far off the coverage
# peak that GenomeScope2 found, rerun with --hom-cov to get balanced haplotypes
log_time "Coverage as inferred by $TOOL_NAME (from the Slurm log):"
grep -h -i "homozygous read coverage\|peak_hom\|peak_het" \
    slurm-"${SLURM_JOB_NAME:-hifiasm}"-"${SLURM_JOB_ID:-}".out 2>/dev/null ||
    echo "  (not found - check the Slurm log manually)"

# Convert the assembly graphs to FASTA
# NOTE: the unitig graphs ('*.r_utg.gfa'/'*.p_utg.gfa') are deliberately skipped
log_time "Converting the assembly GFA files to FASTA..."
shopt -s nullglob
gfas=( "$out_prefix"*.p_ctg.gfa "$out_prefix"*.a_ctg.gfa "$out_prefix"*.p_scaf.gfa )
shopt -u nullglob
[[ ${#gfas[@]} -eq 0 ]] && die "No assembly GFA files found with prefix $out_prefix"
for gfa in "${gfas[@]}"; do
    fasta="${gfa%.gfa}".fasta
    echo "  $(basename "$gfa") => $(basename "$fasta")"
    awk '/^S/ { print ">"$2"\n"$3 }' "$gfa" > "$fasta"
done

log_time "Contig counts and assembly sizes:"
for fasta in "$out_prefix"*.fasta; do
    awk -v f="$(basename "$fasta")" \
        '/^>/ { n++; next } { len += length($0) }
         END { printf "  %-40s %8d seqs %14d bp\n", f, n, len }' "$fasta"
done

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting   # Note: reads the LOG_DIR global, takes no args
