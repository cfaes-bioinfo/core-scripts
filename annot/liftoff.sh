#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=4:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=liftoff
#SBATCH --output=slurm-liftoff-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="
Run Liftoff to transfer gene annotations from a reference assembly to a target assembly.
Always runs with options -copies and -polish."
SCRIPT_VERSION="2026-05-23"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=liftoff
TOOL_NAME=Liftoff
TOOL_DOCS=https://github.com/agshumate/Liftoff
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
container_url=oras://community.wave.seqera.io/library/liftoff_liftofftools:7a69d821dc62677b
container_dir="$HOME/containers"
container_path=

# Constants/hard-coded - tool parameters
# Always runs with options -copies and -polish

# Defaults - tool parameters
coverage=0.5                    # Same as liftoff default
sequence_identity=0.5           # Same as liftoff default
exclude_partial=false

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
            sbatch $0 \
                -i results/asm/novel_genome.fa \
                --ref_fasta data/ref/soybase/glyma.Wm82.gnm1.FCtY.genome_main.fna \
                --ref_gff data/ref/soybase/glyma.Wm82.gnm1.ann1.DvBy.gene_models_main.gff3 \
                -o results/liftoff/novel_from_v1
    
REQUIRED OPTIONS:
  -i/--infile         <file>  Target assembly FASTA (novel genome)
  --ref_fasta         <file>  Reference assembly FASTA used by the source annotation
  --ref_gff           <file>  Reference annotation GFF/GTF to transfer
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --coverage          <float> Minimum feature coverage (-a)                    [default: $coverage]
  --sequence_identity <float> Minimum sequence identity (-s)                   [default: $sequence_identity]
  --exclude_partial           Pass Liftoff -exclude_partial
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
infile=
ref_fasta=
ref_gff=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        --ref_fasta )       shift && ref_fasta=$1 ;;
        --ref_gff )         shift && ref_gff=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --coverage )        shift && coverage=$1 ;;
        --sequence_identity ) shift && sequence_identity=$1 ;;
        --exclude_partial ) exclude_partial=true ;;
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
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$ref_fasta" ]] && die "No reference FASTA specified, do so with --ref_fasta" "$all_opts"
[[ -z "$ref_gff" ]] && die "No reference GFF specified, do so with --ref_gff" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -f "$ref_fasta" ]] && die "Input file $ref_fasta does not exist"
[[ ! -f "$ref_gff" ]] && die "Input file $ref_gff does not exist"

# Make file paths absolute
infile=$(realpath "$infile")
ref_fasta=$(realpath "$ref_fasta")
ref_gff=$(realpath "$ref_gff")
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"

target_base=$(basename "$infile")
target_base=${target_base%.gz}
target_base=${target_base%.*}
out_gff_path="$outdir"/"$target_base".liftoff.gff3
unmapped_path="$outdir"/"$target_base".liftoff.unmapped.txt

intermediate_dir="$outdir"/intermediate_files

# Optional argument snippets
exclude_partial_opt=
[[ "$exclude_partial" == true ]] && exclude_partial_opt="-exclude_partial"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Target assembly FASTA:                    $infile"
echo "Reference assembly FASTA:                 $ref_fasta"
echo "Reference annotation GFF:                 $ref_gff"
echo "Output dir:                               $outdir"
echo "Lifted annotation output:                 $out_gff_path"
echo "Unmapped features output:                 $unmapped_path"
echo "Minimum coverage (-a):                    $coverage"
echo "Minimum sequence identity (-s):           $sequence_identity"
echo "Exclude partial mappings:                 $exclude_partial"
echo "Map extra copies:                         true"
echo "Polish lifted annotation:                 true"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile" "$ref_fasta" "$ref_gff"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
cd "$outdir" || die "Can't change to output dir $outdir"

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    "$infile" \
    "$ref_fasta" \
    -g "$ref_gff" \
    -o "$out_gff_path" \
    -u "$unmapped_path" \
    -dir "$intermediate_dir" \
    -p "$threads" \
    -a "$coverage" \
    -s "$sequence_identity" \
    $exclude_partial_opt \
    -copies \
    -polish \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
