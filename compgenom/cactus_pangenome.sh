#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=20
#SBATCH --mem=80G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=cactus
#SBATCH --output=slurm-cactus-%j.out

#TODO - Use --batchSystem option for full genome runs
#> 2023-06-27: For one tomato chromosome & 6 tomato lines, this only took 100 minutes

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants
readonly DESCRIPTION="Run cactus-pangenome to align multiple genomes/chromosomes\n
of the same or closely related species. Output includes a VCF file."
readonly SCRIPT_NAME=cactus_pangenome.sh
readonly SCRIPT_VERSION="1.0"
readonly SCRIPT_AUTHOR="Jelmer Poelstra"
readonly SCRIPT_URL=https://github.com/mcic-osu/mcic-scripts
readonly TOOL_BINARY=cactus-pangenome
readonly TOOL_NAME=Cactus-pangenome
readonly TOOL_DOCS=https://github.com/ComparativeGenomicsToolkit/cactus/blob/master/doc/pangenome.md
readonly CONTAINER_URL=docker://quay.io/comparative-genomics-toolkit/cactus:latest

# Option defaults
restart=true            # Attempt to restart - will be set to false if there is no 'jobstore' dir
outfile_prefix=cactus
container_path=/fs/ess/PAS0471/containers/cactus_v2.6.0.sif
rebuild_container=false

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo
    echo "        $0 (v. $SCRIPT_VERSION): Run $TOOL_NAME"
    echo "        =============================================="
    echo "DESCRIPTION:"
    echo -e "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage (always submit your scripts to SLURM with 'sbatch'):"
    echo "      sbatch $0 -i data/genomes -o results/cactus --ref_id genomeA"
    echo "  - To just print the help message for this script (-h) or for $TOOL_NAME (--help):"
    echo "      bash $0 -h"
    echo "      bash $0 --help"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <file>  Input dir with FASTA files"
    echo "                                Files should have the extension '.fna', '.fa', or '.fasta' -- others will be ignored"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo " --ref_id             <str>   ID of reference genome/FASTA"
    echo "                                This should exactly match the name of a provided FASTA file, minus the file extension"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --outfile_prefix    <str>   Output file prefix                      [default: 'cactus']"
    echo "  --no_restart                Don't attempt to restart a previous run [default: restart if there is a 'jobstore' in the output dir]"
    echo "  --more_args         <str>   Quoted string with more argument(s) for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --container_path    <file>  Use the specified container SIF file    [default: use $container_path]"
    echo "  --rebuild_container         Rebuild the container from quay.io/comparative-genomics-toolkit/cactus:latest, e.g. to update to latest version [default: use $container_path]"
    echo "  -h                          Print this help message and exit"
    echo "  --help                      Print the help for $TOOL_NAME and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  -v/--version                Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION:"
    echo "  - Docs: $TOOL_DOCS"
    echo
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

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
indir=
outdir=
ref_id=
more_args=

# Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )          shift && readonly indir=$1 ;;
        -o | --outdir )         shift && readonly outdir=$1 ;;
        --ref_id )              shift && readonly ref_id=$1 ;;
        --outfile_prefix )      shift && readonly outfile_prefix=$1 ;;
        --no_restart )          restart=false ;;
        --rebuild_container )   readonly rebuild_container=true ;;
        --container_path )      readonly container_path=$1 ;;
        --more_args )           shift && readonly more_args=$1 ;;
        -h )                    script_help; exit 0 ;;
        -v | --version )             print_version; exit 0 ;;
        --help )                tool_help; exit 0;;
        * )                     die "Invalid option $1" "$all_args" ;;
    esac
    shift
done

# Check input
[[ -z "$indir" ]] && die "No input file specified, do so with -i/--indir" "$all_args"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_args"
[[ -z "$ref_id" ]] && die "No reference genome ID specified, do so with --ref_id" "$all_args"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Check if this is a SLURM job
if [[ -z "$SLURM_JOB_ID" ]]; then is_slurm=false; else is_slurm=true; fi

# Strict bash settings
set -euo pipefail

# Source the Bash functions script
source_function_script

# Logging files and dirs
readonly log_dir="$outdir"/logs
readonly version_file="$log_dir"/version.txt
readonly env_file="$log_dir"/env.txt
mkdir -p "$log_dir"

# Load software and set nr of threads
set_threads

# Full call to the tool
readonly TOOL_BINARY="singularity exec $container_path $TOOL_BINARY_PART"

# Restart a previous run?
jobstore_dir="$outdir"/jobstore
if [[ "$restart" == "true" ]]; then
    restart_arg="--restart"
    [[ ! -d "$jobstore_dir" ]] && restart=false # Cant restart if the jobstore doesnt exist
fi
if [[ "$restart" == "false" ]]; then
    restart_arg=
    [[ -d "$jobstore_dir" ]] && rm -r "$jobstore_dir" # Cactus will complain if this exists when not restarting
fi

# Create the 'sequence file' (FOFN) - first column with file IDs, second column with file paths
seqfile="$outdir"/seqfile.txt
if [[ "$restart" == "false" ]]; then
    paste \
        <(find "$indir" -name "*fasta" -or -name "*fna" -or -name "*fna" | \
          xargs -n 1 basename | sed -E 's/\.[^\.]+//') \
        <(find "$indir" -name "*fasta" -or -name "*fna" -or -name "*fna") \
        > "$seqfile"
fi

# Check the seqfile
nfasta=$(wc -l < "$seqfile")
[[ "$nfasta" -eq 0 ]] && die "No FASTA files detected in $indir"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:             $all_args"
echo "Input dir:                                $indir"
echo "Nr of FASTA files in the input dir:       $nfasta"
echo "Output dir:                               $outdir"
echo "Reference genome ID:                      $ref_id"
echo "Output file prefix:                       $outfile_prefix"
echo "Restart previous run?                     $restart"
[[ -n $more_args ]] && echo "Other arguments for $TOOL_NAME:   $more_args"
echo "Number of threads/cores:                  $threads"
echo
log_time "Listing the input file(s):"
ls -lh "$indir" "$seqfile"
log_time "Pringing the contents of the 'seqfile':"
cat "$seqfile"
[[ "$is_slurm" = true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Rebuild the container SIF if needed
if [[ "$rebuild_container" == "true" ]]; then
    log_time "Rebuilding container SIF file from the internet..."
    singularity build "$container_path" "$CONTAINER_URL"
fi

# Run Cactus
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    "$jobstore_dir" \
    "$seqfile" \
    --outDir "$outdir" \
    --outName "$outfile_prefix" \
    --reference "$ref_id" \
    --vcf \
    --giraffe \
    --gfa \
    --gbz \
    --maxCores "$threads" \
    $restart_arg \
    $more_args

# List the output
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*

# ==============================================================================
#                               WRAP UP
# ==============================================================================
printf "\n======================================================================"
log_time "Versions used:"
print_version | tee "$version_file"
script_version | tee -a "$version_file" 
env | sort > "$env_file"
[[ "$is_slurm" = true ]] && echo && resource_usage
log_time "Done with script $SCRIPT_NAME\n"
