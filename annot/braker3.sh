#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=32:00:00
#SBATCH --cpus-per-task=15
#SBATCH --mem=60G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=braker3
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Braker3 to annotate a genome assembly.
As 'evidence' for annotation, provide RNAseq data of the same species and/or
protein data of the same or related species."
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=braker.pl
TOOL_NAME=Braker3
TOOL_DOCS=https://github.com/Gaius-Augustus/BRAKER
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
env_type=container          # 'conda' / 'container' / 'none'
container_url=
container_dir="$HOME/containers" # Where to download a container to (if needed)
container_path=/fs/ess/PAS0471/containers/braker3.sif # Full path to a pre-downloaded container image
conda_path=

# Defaults - tool parameters
rebuild_container=false     # If true, pulls and builds (from Docker) latest Braker container
is_fungus=false

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
  - Provide both RNAseq and protein data:
      sbatch $0 -i results/genome.fa -o results/braker --rnaseq_fqdir data/rnaseq --prot_file data/ref/proteins.faa --species homo_sapiens
  - Provide only protein data, and use the '--fungus' option:
      sbatch $0 -i results/genome.fa -o results/braker --prot_file data/ref/proteins.faa --species candida_albicans --fungus
  - Provide RNAseq data via SRA IDS: the corresponding FASTQ files will be downloaded
      sbatch $0 -i results/genome.fa -o results/braker --rnaseq_sra_ids SRR5506722,SRR6942483,SRR21195554 --species homo_sapiens
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i results/genome.fa -o results/braker --species homo_sapiens --prot_file data/ref/proteins.faa --more_opts \"--gff3\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input assembly nucleotide FASTA
  -o/--outdir         <dir>   Output dir (will be created if needed)
  --species           <str>   Species name (without space, e.g. 'homo_sapiens')

OTHER KEY OPTIONS:
  --rnaseq_fqdir      <dir>   Directory with RNAseq FASTQ files
                              NOTE: FASTQs should be unzipped, and end in '_1.fastq' / '_2.fastq' for R1/R2 reads
  --rnaseq_sra_ids    <str>   Comma-separated list of RNAseq SRA IDs, e.g. 'SRR5506722,SRR6942483,SRR21195554'
  --prot_file         <file>  FASTA file with reference proteins. For info on how to create this file:
                              https://github.com/gatech-genemark/ProtHint#protein-database-preparation
  --fungus                    Use a fungus-specific annotation model implemented in Braker
  --rebuild_container         Force a redownload of the container     [default: $rebuild_container]
                                This will pull from docker://teambraker/braker3:latest, and would therefore update to the latest version
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
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
  --container_url     <str>   URL/URI to download a container from              [default: ${container_url:-none}]
                              (only used when no container path is set)
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_path    <file>  Local container image file ('.sif') to use        [default: ${container_path:-none}]
  --conda_path        <dir>   Full path to a Conda environment to use           [default: ${conda_path:-none}]
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
species=
outdir=
prot_file= && prot_opt=
rnaseq_fqdir= && rnaseq_opt=
rnaseq_sra_ids=
fungus_opt=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )         check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )         check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --species )             check_val "$1" "${2:-}"; shift; species=$1 ;;
        --prot_file )           check_val "$1" "${2:-}"; shift; prot_file=$1 ;;
        --rnaseq_fqdir )        check_val "$1" "${2:-}"; shift; rnaseq_fqdir=$1 ;;
        --rnaseq_sra_ids )      check_val "$1" "${2:-}"; shift; rnaseq_sra_ids=$1 ;;
        --fungus )              is_fungus=true ;;
        --rebuild_container )   rebuild_container=true ;;
        --more_opts )           check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
        --env_type )            check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )          check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )       check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )       check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )      check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version)         version_only=true ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
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

# Print version info and exit, if requested (this needs the software env loaded)
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# GeneMark license key - See https://github.com/Gaius-Augustus/BRAKER#genemark-ex
#GENEMARK_BASEDIR=/fs/ess/PAS0471/jelmer/software/genemark-ex
#cp "$GENEMARK_BASEDIR"/gm_key_64 ~/.gm_key

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$species" ]] && die "Please specify a species name with --species" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ -n "$prot_file" && ! -f "$prot_file" ]] && die "Protein seq file $prot_file does not exist"
[[ -n "$rnaseq_fqdir" && ! -d "$rnaseq_fqdir" ]] && die "RNAseq FASTQ dir $rnaseq_fqdir does not exist"

# Warn if the output dir already holds results from a previous run
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"

# Make input paths absolute
infile=$(realpath "$infile")
[[ -n "$prot_file" ]] && prot_file=$(realpath "$prot_file")
[[ -n "$rnaseq_fqdir" ]] && rnaseq_fqdir=$(realpath "$rnaseq_fqdir")

# Protein sequence file
[[ -n "$prot_file" ]] && prot_opt="--prot_seq=$(printf '%q' "$prot_file")"

# RNAseq data argument
if [[ -n "$rnaseq_fqdir" ]]; then
    fq_ids=$(ls "$rnaseq_fqdir"/*fastq | xargs -n1 basename | sed 's/_[12].fastq//' |
             sort | uniq | tr "\n" "," | sed 's/,$/\n/')
    rnaseq_opt="--rnaseq_sets_dirs=$(printf '%q' "$rnaseq_fqdir") --rnaseq_sets_ids=$fq_ids"
elif [[ -n "$rnaseq_sra_ids" ]]; then
    rnaseq_opt="--rnaseq_sets_ids=$rnaseq_sra_ids"
fi

# Augustus config dir
augustus_config_dir="$PWD"/"$outdir"/augustus_config
augustus_config_opt="--AUGUSTUS_CONFIG_PATH=$(printf '%q' "$augustus_config_dir")"

# Fungus option
[[ "$is_fungus" == true ]] && fungus_opt="--fungus"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input assembly file:                      $infile"
echo "Output dir:                               $outdir"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
echo "Species:                                  $species"
[[ -n $rnaseq_opt ]] && echo "RNAseq data option:                       $rnaseq_opt"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ -n "$prot_file" ]] && ls -lh "$prot_file"
[[ -n "$rnaseq_fqdir" ]] && ls -lh "$rnaseq_fqdir"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Rebuild the container SIF if needed
if [[ "$rebuild_container" == "true" ]]; then
    log_time "Rebuilding container SIF file from the internet..."
    singularity build --force "$container_path" docker://teambraker/braker3:latest
fi

# Load the software environment
load_env

# Copy the Augustus config dir from the container
# This is needed because Braker will otherwise try to write inside the container
log_time "Copying the Augustus config dir from the container..."
singularity exec -B "$PWD":"$PWD" "$container_path" \
    cp -r /opt/Augustus/config/ "$augustus_config_dir"
#    cp -r /usr/share/augustus/config/ "$augustus_config_dir"

# Run the tool
log_time "Running $TOOL_NAME..."
eval runstats "$TOOL_BINARY" \
    --workingdir="$(printf '%q' "$outdir")" \
    --genome="$(printf '%q' "$infile")" \
    $prot_opt \
    $rnaseq_opt \
    $augustus_config_opt \
    $fungus_opt \
    --species="$species" \
    --verbosity=3 \
    --threads="$threads" \
    $more_opts

#? Other useful Braker options:
#  --gff3               Output a GFF3 instead of a GTF file
#  --useexisting        Use the present config and parameter files if they exist for 'species';
#                       will overwrite original parameters if BRAKER performs an AUGUSTUS training.

# Report number of genes and transcripts
if [[ -f "$outdir"/braker.gtf ]]; then
    ngenes=$(awk '$3 == "gene"' "$outdir"/braker.gtf | wc -l)
    log_time "Number of genes in the output:        $ngenes"
else
    log_time "NOTE: Can't find output file $outdir/braker.gtf to count the nr of genes"
fi
if [[ -f "$outdir"/braker.aa ]]; then
    ntrans=$(grep -c "^>" "$outdir"/braker.aa)
    log_time "Number of transcripts in the output:  $ntrans"
else
    log_time "NOTE: Can't find output file $outdir/braker.aa to count the nr of transcripts"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
final_reporting
