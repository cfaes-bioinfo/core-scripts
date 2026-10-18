#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=15
#SBATCH --mem=60G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=bcftools-call
#SBATCH --output=slurm-bcftools-call-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run 'bcftools mpileup' and 'bcftools call' to call variants using BAM files and a reference FASTA"
SCRIPT_VERSION="2026-03-21"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=        # Leave empty so it will just be replaced by the container call
TOOL_NAME=BCFtools
TOOL_DOCS="https://samtools.github.io/bcftools/bcftools.html; https://samtools.github.io/bcftools/howtos/variant-calling.html"
VERSION_COMMAND="bcftools --version"

# Defaults - generics
env_type=container                  # Use a 'conda' env or a Singularity 'container'
conda_path=
# Container has samtools v1.21 and bcftools v1.23
container_url=oras://community.wave.seqera.io/library/bcftools_samtools:7fe67bba6ab148dd
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters
VARCALL_METHOD="--multiallelic-caller"

# Defaults - tool parameters
allsites=false      # Only output variant sites
maxdepth=500        # Vs. mpileup default of 250

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
      sbatch $0 --fasta data/assembly.fa --bam_dir results/bwa -o results/mpileup.vcf
    
REQUIRED OPTIONS:
  --ref_fasta         <file>  Input reference FASTA file
  --bam_dir           <dir>   Directory with input BAM files
  -o/--vcf            <file>  Output gzipped VCF file (extension 'vcf.gz')
    
OTHER KEY OPTIONS:
  --allsites                  Output ALL sites in the VCF, not just variants
  --maxdepth          <int>   Max depth for mpileup                             [default: $maxdepth]
                                Note: this applies separately for each BAM file.
                                A higher value is mostly needed for BAM files
                                that have been merged across samples.
  --opts_mpileup      <str>   Quoted string with additional argument(s) for bcftools mpileup
  --opts_call         <str>   Quoted string with additional argument(s) for bcftools call
    
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
fasta=
bam_dir=
vcf=
opts_mpileup=
opts_call=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --ref_fasta )       shift && fasta=$1 ;;
        --bam_dir )         shift && bam_dir=$1 ;;
        -o | --vcf )        shift && vcf=$1 ;;
        --maxdepth )        shift && maxdepth=$1 ;;
        --allsites )        allsites=true ;;
        --opts_mpileup )    shift && opts_mpileup=$1 ;;
        --opts_call )       shift && opts_call=$1 ;;
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
[[ -z "$fasta" ]] && die "No input reference genome FASTA file specified, do so with --ref_fasta" "$all_opts"
[[ -z "$bam_dir" ]] && die "No dir with BAM files specified, do so with --bam_dir" "$all_opts"
[[ -z "$vcf" ]] && die "No output VCF file specified, do so with -o/--vcf" "$all_opts"
[[ ! -f "$fasta" ]] && die "Input reference genome FASTA file $fasta does not exist"
[[ ! -d "$bam_dir" ]] && die "BAM directory $bam_dir does not exist"

# Define outputs based on script parameters
outdir=$(dirname "$vcf")
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
if [[ "$allsites" == true ]]; then allsites_opt=; else allsites_opt="-v"; fi

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input reference genome FASTA file:        $fasta"
echo "BAM directory:                            $bam_dir"
echo "Number of BAM files:                      $(ls "$bam_dir"/*bam | wc -l)"
echo "Output all sites in the VCF:              $allsites"
echo "Max depth for mpileup:                    $maxdepth"
echo "Output VCF file:                          $vcf"
[[ -n $opts_mpileup ]] && echo "Additional options for mpileup:          $opts_mpileup"
[[ -n $opts_call ]] && echo "Additional options for call:             $opts_call"
log_time "Listing the input file(s):"
ls -lh "$fasta" "$bam_dir"/*bam
[[ "$IS_SLURM" == true ]] && slurm_resources
set_threads "$IS_SLURM"

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY bcftools mpileup \
    --max-depth "$maxdepth" \
    --fasta-ref "$fasta" \
    --output-type u \
    $opts_mpileup \
    "$bam_dir"/*bam |
    runstats $TOOL_BINARY bcftools call \
        "$VARCALL_METHOD" \
        --output "$vcf" \
        --output-type z \
        --threads "$threads" \
        --write-index \
        $opts_call \
        $allsites_opt

#? '--output-type u/z' => uncompressed BCF / compressed VCF
#? -m: default calling methods (vs -c, old consensus calling method)

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing the output VCF file:"
ls -lh "$vcf"
final_reporting "$LOG_DIR"
