#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mail-type=FAIL
#SBATCH --job-name=snpeff-build
#SBATCH --output=slurm-snpeff-build-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Build a SnpEff database for a specific genome"
SCRIPT_VERSION="2025-05-26"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=snpEff
TOOL_NAME=snpEff
TOOL_DOCS=https://pcingola.github.io/SnpEff/snpeff
VERSION_COMMAND="$TOOL_BINARY -version"

# Defaults - generics
env_type=conda
conda_path=/fs/ess/PAS0471/jelmer/conda/snpeff
container_dir="$HOME/containers"
container_url=
container_path=

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
      sbatch $0 -i results/gatk/my.vcf -o results/snpeff \
        --genome_id GCA_047496595.1 --species my_species \
        --config results/snpeff/snpEff.config
    
REQUIRED OPTIONS:
  --fna               <file>  Input genome assembly file in FASTA format
  --gtf               <file>  Input genome annotation file in GTF (v. 2.2) format
                                Don't use GFF3 files: if needed, first convert with
                                mcic-scripts/convert/gff2gtf_agat.sh
  --genome_id         <str>   Genome ID to use (use this ID again when running SnpEff)
  --species           <str>   Species name with underscore, e.g. 'Triticum_aestivum'
  --config            <file>  Path to a NEW SnpEff config file to create ('.config' extension)
                                Use a dedicated dir for this, as the database
                                files will be created in the same dir.
                                (Use this again when running SnpEff.)
    
OTHER KEY OPTIONS:
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME
    
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
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false          # When true, just print tool & script version info and exit
fna=
gtf=
genome_id=
species=
config=
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        --fna )             shift && fna=$1 ;;
        --gtf )             shift && gtf=$1 ;;
        --genome_id )       shift && genome_id=$1 ;;
        --species )         shift && species=$1 ;;
        --config )          shift && config=$1 ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )        shift && env_type=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )    version_only=true ;;
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
[[ -z "$fna" ]] && die "No input assembly file specified, do so with --fna" "$all_opts"
[[ -z "$gtf" ]] && die "No input GTF file specified, do so with --gtf" "$all_opts"
[[ -z "$species" ]] && die "No species name specified, do so with --species" "$all_opts"
[[ -z "$config" ]] && die "No config file specified, do so with --config" "$all_opts"
[[ -z "$genome_id" ]] && die "No genome ID specified, do so with --genome_id" "$all_opts"
[[ ! -f "$fna" ]] && die "Input assembly file $fna does not exist"
[[ ! -f "$gtf" ]] && die "Input GTF file $gtf does not exist"

# Define outputs based on script parameters
outdir=$(dirname "$config")
data_dir="$outdir"/data/"$genome_id"
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input genome FASTA file:                  $fna"
echo "Input genome GTF file:                    $gtf"
echo "Genome ID:                                $genome_id"
echo "Species:                                  $species"
echo "Output config file:                       $config"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$fna" "$gtf"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Copy the genome assembly and annotation into the SnpEff data dir
log_time "Copying genome assembly and annotation to the SnpEff data dir..."
mkdir -p "$data_dir"
cp -v "$fna" "$data_dir"/sequences.fa
cp -v "$gtf" "$data_dir"/genes.gtf

# Edit the snpEff.config file
log_time "Creating SnpEff config file..."
echo -e "\ndata.dir = ./data/" > "$config"
echo -e "\n# $species genome, version $genome_id" >> "$config"
echo -e "${genome_id}.genome : $species\n" >> "$config"
log_time "Printing the contents of their SnpEff config file:"
cat -n "$config"

# Run SnpEff build
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY build \
    -gtf22 \
    -verbose \
    -noCheckCds \
    -noCheckProtein \
    -nodownload \
    -config $config \
    $genome_id

#? Protein checks seem to usually fail, so skip them
#? See also https://pcingola.github.io/SnpEff/snpeff/build_db

# Report
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
