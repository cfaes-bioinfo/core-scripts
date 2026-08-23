#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=salmon
#SBATCH --output=slurm-salmon-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Quantifying RNASeq reads with Salmon in alignment-based mode (i.e., with a BAM file)"
SCRIPT_VERSION="2023-10-21"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY="salmon quant"
TOOL_NAME=Salmon
TOOL_DOCS=https://salmon.readthedocs.io/en/latest/salmon.html
VERSION_COMMAND="salmon --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/salmon # NOTE: Also includes RSEM
container_path=/fs/ess/PAS0471/containers/depot.galaxyproject.org-singularity-salmon-1.10.1--h7e5ed60_0.img
container_url=
dl_container=false
container_dir="$HOME/containers"
strict_bash=true

# Defaults - tool parameters
libtype=ISR                         # Default = reverse-stranded
gcbias_opt="--gcBias"               # Include the --gcBias option
#?(gcBias opt recommended here: http://bioconductor.org/packages/devel/bioc/vignettes/DESeq2/inst/doc/DESeq2.html)
seqbias_opt="--seqBias"             # Include the --seqBias option (https://salmon.readthedocs.io/en/latest/salmon.html#seqbias)

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/star/my.bam -a data/ref/annot.gtf --transcripts \\"
    echo "          results/rsem/transcripts.fa -o results/salmon/sampleA"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input BAM file"
    echo "  -a/--annot          <file>  Reference annotation (GFF/GTF) file"
    echo "  --transcripts       <file>  Transcripts FASTA file - use mcic-scripts/rnaseq/rsem_prepref.sh to generate"
    echo "  -o/--outdir         <dir>   Sample-specific (!) output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --libtype           <str>   RNAseq library type                     [default: $libtype]"
    echo "                              (see https://salmon.readthedocs.io/en/latest/salmon.html#what-s-this-libtype)"
    echo "  --no_gcbias                 Don't use the Salmon '--gcBias' option  [default: use (note: this is not the Salmon default)]"
    echo "  --no_seqbias                Don't use the Salmon '--seqBias' option [default: use (note: this is not the Salmon default)]"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "                                (NOTE: If no default '--container_url' is listed below,"
    echo "                                 you'll have to provide one in order to run the script with a container.)"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or '--dl_container' is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  --no_strict                 Don't use strict Bash settings ('set -euo pipefail') -- can be useful for troubleshooting"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
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
    function_script=$(realpath "$script_dir"/../dev/"$(basename "$FUNCTION_SCRIPT_URL")")
    # Download the function script if needed, then source it
    if [[ ! -f "$function_script" ]]; then
        echo "Can't find script with Bash functions ($function_script), downloading from GitHub..."
        function_script=$(basename "$FUNCTION_SCRIPT_URL")
        wget "$FUNCTION_SCRIPT_URL" -O "$function_script"
    fi
    source "$function_script"
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
infile=
annot=
transcripts=
outdir=
opts=
version_only=false
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -o | --outdir )     shift && outdir=$1 ;;
        -i | --infile )     shift && infile=$1 ;;
        -a | --annot )      shift && annot=$1 ;;
        --transcripts )     shift && transcripts=$1 ;;
        --libtype )         shift && libtype=$1 ;;
        --opts )            shift && opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --no_gcbias )       gcbias_opt= ;;
        --no_seqbias )      seqbias_opt= ;;
        --no_strict )       strict_bash=false ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
[[ "$strict_bash" == true ]] && set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input BAM file:                           $infile"
echo "Reference annotation file:                $annot"
echo "Transcripts FASTA file:                   $transcripts"
echo "Output dir:                               $outdir"
echo "RNAseq library type:                      $libtype"
[[ -n "$gcbias_opt" ]] && echo "Using Salmon's --gcBias option"
[[ -n "$seqbias_opt" ]] && echo "Using Salmon's --seqBias option"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$infile" "$annot"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --geneMap "$annot" \
    --threads "$threads" \
    --libType="$libtype" \
    -t "$transcripts" \
    -a "$infile" \
    -o "$outdir" \
    "$gcbias_opt" \
    "$seqbias_opt" \
    $opts

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
