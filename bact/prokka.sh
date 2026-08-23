#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=30
#SBATCH --cpus-per-task=12
#SBATCH --mem=48G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --job-name=prokka
#SBATCH --output=slurm-prokka-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Annotate a prokaryotic genome assembly with Prokka"
SCRIPT_VERSION="2026-08-23"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=prokka
TOOL_NAME=Prokka
TOOL_DOCS=https://github.com/tseemann/prokka
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                      # 'conda' or 'container'
container_path=/fs/ess/PAS0471/containers/prokka:1.14.6--pl5321hdfd78af_4
container_url=https://depot.galaxyproject.org/singularity/prokka:1.14.6--pl5321hdfd78af_4
conda_path=
dl_container=false
container_dir="$HOME/containers"

# Defaults - settings
gff_noseqs=false                # Don't create a copy of the GFF file without annotations at the end

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo "                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i results/spades/assembly.fasta -o results/prokka"
    echo "  - It's recommended to provide species information:"
    echo "      sbatch $0 -i results/spades/assembly.fasta --genus salmonella --species enterica"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--infile         <file>  Input file"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --genus             <str>   Genus name of the focal organism (e.g. 'salmonella')    [default: none]"
    echo "  --species           <str>   Species name of the focal organism (e.g. 'enterica')    [default: none]"
    echo "  --strain            <str>   Strain name of the focal organism                       [default: none]"
    echo "  --prefix            <str>   Prefix for output file names                            [default: basename minus extension of input file]"
    echo "  --gff_noseqs                Create a copy of the GFF file that has no DNA sequences [default: no copy]"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "  --container_url     <str>   URL to download the container from                      [default: $container_url]"
    echo "  --container_dir     <str>   Dir to download the container to                        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container                     [default: false]"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION: $TOOL_DOCS"
    echo
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
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
infile=
outdir=
genus= && genus_arg=
species= && species_arg=
strain= && strain_arg=
out_prefix=
opts=
version_only=false

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --genus )           shift && genus=$1 ;;
        --species )         shift && species=$1 ;;
        --strain )          shift && strain=$1 ;;
        --prefix )          shift && out_prefix=$1 ;;
        --gff_noseqs )      gff_noseqs=true ;;
        --opts )            shift && opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
        * )                 die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software and set nr of threads
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
[[ -n "$genus" ]] && genus_arg="--genus $genus"
[[ -n "$species" ]] && species_arg="--species $species"
[[ -z "$out_prefix" ]] && out_prefix=$(basename "${infile%.*}")

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_args"
echo "Input assembly FASTA:                     $infile"
echo "Output dir:                               $outdir"
echo "Output file prefix:                       $out_prefix"
echo "Create a copy of the GFF file wo/ seqs:   $gff_noseqs"
[[ -n "$genus" ]] && echo "Genus:                                    $genus"
[[ -n "$species" ]] && echo "Species:                                  $species"
[[ -n "$strain" ]] && echo "Strain:                                   $strain"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --outdir "$outdir" \
    --prefix "$out_prefix" \
    --cpus "$threads" \
    --force \
    $genus_arg \
    $species_arg \
    $strain_arg \
    $opts \
    "$infile"

#? Other options:
# --usegenus        Apparently no longer recommended, use `--proteins` instead
# --addgenes        Add 'gene' features for each 'CDS' feature (default OFF)

if [[ "$gff_noseqs" == true ]]; then
    log_time "Creating a copy of the GFF file without DNA sequences..."
    sed '/^##FASTA/Q' "$outdir"/"$out_prefix".gff > "$outdir"/"$out_prefix"_noseqs.gff
fi

# List the output, report version, etc
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/"$out_prefix"*
final_reporting "$LOG_DIR"
