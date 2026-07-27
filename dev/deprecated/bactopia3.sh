#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=10
#SBATCH --mem=40G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=bactopia3
#SBATCH --output=slurm-bactopia3-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run the Bactopia v3 workflow"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=bactopia
TOOL_NAME=Bactopia
TOOL_DOCS=https://bactopia.github.io/
VERSION_COMMAND="bactopia --version"

# Constants - Nextflow and Bactopia generic settings
# Note: The samplesheet will be saved in $outdir/samplesheet.tsv 
OSC_CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/nextflow/osc.config
OSC_CONFIG=mcic-scripts/nextflow/osc.config     # Will be downloaded if not present here
QUEUE_SIZE=100                                  # Nr of jobs to be submitted at once
MAX_TIME=1440                                   # In hours
MAX_MEM=128                                     # In GB
MAX_CPUS=48
MAX_RETRY=1                                     # Retry failed jobs just once

# Defaults - Nextflow generics
work_dir_default=/fs/scratch/$SLURM_JOB_ACCOUNT/$USER/bactopia
container_dir=/fs/ess/PAS0471/containers
profile=singularity
resume=true && resume_opt="-resume"

# Defaults - other generics
env_type=conda                                       # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/bactopia3
version_only=false                              # When true, just print tool & script version info and exit

# Defaults - Bactopia settings
annotater=bakta                                 # Differs from Bactopia default (Prokka)
assembler=spades                                # Differs from Bactopia default (Skesa)

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
script_help() {
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage:"
    echo "      sbatch $0 -i data/fastq -o results/bactopia --species 'Salmonella enterica' --bakta_db /fs/ess/PAS0471/jelmer/refdata/bakta/db"
    echo "  - Use Prokka instead of Bakta for annotation:"
    echo "      sbatch $0 -i data/fastq -o results/bactopia --species 'Salmonella enterica' --use_prokka"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--indir          <dir>   Input dir with FASTQ files"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  --species           <str>   Focal species, e.g. 'Salmonella enterica' (make sure to quote!)"
    echo "  --bakta_db          <dir>   Dir with Bakta DB, required when using Bakta for annotation (use '--use_prokka' to use Prokka instead)"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --assembler         <str>   Which assembler to use inside Shovill                           [default: spades]"
    echo "                              Options: 'spades', 'skesa', 'megahit', 'velvet'"
    echo "  --annotater         <str>   Which annotation program to use, options: 'prokka', 'bakta'     [default: bakta]"
    echo "  --amr_organism      <str>   Organism name for AMRFinder+                                    [default: none]"
    echo "  --more_opts         <str>   Quoted string with additional argument(s) for $TOOL_NAME"
    echo "  --restart                   Don't attempt to resume workflow run, but always start over     [default: resume any previous run]"
    echo 
    echo "GENERAL NEXTFLOW OPTIONS:"
    echo "  --work_dir          <dir>   Dir for initial workflow output files                           [default: /fs/scratch/$SLURM_JOB_ACCOUNT/$USER/bactopia]"
    echo "  --config            <file>  Additional Nextflow config file                                 [default: none - but mcic-scripts OSC config will be used]"
    echo "                                - Settings in this file will override default settings"
    echo "                                - Note that the mcic-scripts OSC config file will always be included, too"
    echo "                                  (https://github.com/mcic-osu/mcic-scripts/blob/main/nextflow/osc.config)"
    echo "  --container_dir     <dir>   Directory with/for stored container images                      [default: $container_dir]"
    echo "  --profile           <str>   Nextflow 'Profile' to use from one of the config files          [default: 'singularity']"
    echo "                              Use 'none' to not load a profile at all"
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h/--help                   Print this help message and exit"
    echo "  -v                          Print the version of this script and exit"
    echo "  --version                   Print the version of $TOOL_NAME and exit"
    echo
    echo "TOOL DOCUMENTATION:"
    echo "  - $TOOL_DOCS"
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
        wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script"
    fi
    source "$function_script"
}

nextflow_env() {
    # Singularity container dir - any downloaded containers will be stored here;
    # if the required container is already there, it won't be re-downloaded
    export NXF_SINGULARITY_CACHEDIR="$container_dir"
    mkdir -p "$NXF_SINGULARITY_CACHEDIR"
    # Limit memory for Nextflow main process - see https://www.nextflow.io/blog/2021/5_tips_for_hpc_users.html
    export NXF_OPTS='-Xms1g -Xmx4g'
}

# ==============================================================================
#                          INFRASTRUCTURE SETUP I
# ==============================================================================
# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
indir=
outdir=
species=
bakta_db=
annot_opt=
amr_organism= && amr_organism_opt=
config_file=
work_dir=
profile_opt=
conda_dir= && conda_dir_opt=
more_opts=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )      shift && indir=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --species )         shift && species=$1 ;;
        --bakta_db )        shift && bakta_db=$1 ;;
        --annotater )       shift && annotater=$1 ;;
        --assembler )       shift && assembler=$1 ;;
        --amr_organism )    shift && amr_organism=$1 ;;
        --container_dir )   shift && container_dir=$1 ;;
        --conda_dir )       shift && conda_dir=$1 ;;
        --config )          shift && config_file=$1 ;;
        --profile )         shift && profile=$1 ;;
        --work_dir )        shift && work_dir=$1 ;;
        -restart )          resume=false && resume_opt= ;;
        --more_opts )       shift && more_opts=$1 ;;
        --env_type )             shift && env_type=$1 ;;
        --dl_container )    dl_container=true ;;
        --container_dir )   shift && container_dir=$1 ;;
        --container_url )   shift && container_url=$1 && dl_container=true ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version )         version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# Check arguments
[[ -z "$indir" ]] && die "No input dir specified, do so with -i/--indir" "$all_opts"
[[ -z "$species" ]] && die "No species specified, do so with --species" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -d "$indir" ]] && die "Input dir $indir does not exist"

# ==============================================================================
#                          INFRASTRUCTURE SETUP II
# ==============================================================================
# Strict bash settings
set -euo pipefail

# Outputs - make paths absolute
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"
[[ ! "$OSC_CONFIG" =~ ^/ ]] && OSC_CONFIG="$PWD"/"$OSC_CONFIG"

# Logging files and dirs
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# Load software
load_env "$conda_path"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0
nextflow_env

# Get the OSC config file, then build the config argument
[[ ! -f "$OSC_CONFIG" ]] && OSC_CONFIG="$outdir"/$(basename "$OSC_CONFIG_URL")
config_opt="-c $OSC_CONFIG"
[[ -n "$config_file" ]] && config_opt="$config_opt -c ${config_file/,/ -c }"

# Set Nextflow 'work' dir
if [[ -z "$work_dir" && "$IS_SLURM" == true ]]; then
    work_dir="${work_dir_default/pas/PAS}"  # 'pas' is in lowercase otherwise! 
else
    work_dir="$outdir"/work
fi

# Profile
if [[ "$profile" != "none" ]]; then
    profile_opt="-profile $profile"
else
    profile_opt="--use_mamba"
fi

# Conda env dir
[[ -n "$conda_dir" ]] && conda_dir_opt="--condadir $conda_dir"

# Define outputs
run_name=$(basename "$outdir")
[[ "$run_name" == "bactopia" ]] && run_name=bactopia_run  # Run name can't be 'bactopia', gives problems
samplesheet="$outdir"/samplesheet.tsv

# Annotater argument 
if [[ "$annotater" == "bakta" ]]; then
    [[ -z "$bakta_db" ]] && die "Using Bakta, but no Bakta DB dir specified, do so with --bakta_db" "$all_opts"
    [[ ! -d "$bakta_db" ]] && die "Bakta DB dir $bakta_db does not exist"
    annot_opt="--use_bakta --bakta_db $bakta_db"
fi

# AMRFinder+ organism
[[ -n "$amr_organism" ]] && amr_organism_opt="--organism $amr_organism"

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:             $all_opts"
echo
echo "INPUT AND OUTPUT:"
echo "Input FASTQ dir:                          $indir"
echo "Output dir:                               $outdir"
[[ "$annotater" == "bakta" ]] && echo "Bakta DB dir:                             $bakta_db"
echo "Nr of FASTQ files in the input dir:       $(ls "$indir"/*fastq.gz | wc -l)"
echo
echo "SETTINGS:"
echo "Species:                                  $species"
echo "Genome assembler (within Shovill):        $assembler"
echo "Genome annotater:                         $annotater"
[[ -n "$amr_organism" ]] && echo "AMRFinder+ organism:                      $amr_organism"
[[ -n "$more_opts" ]] && echo "More args for Bactopia:                   $more_opts"
echo
echo "NEXTFLOW-RELATED SETTINGS:"
echo "Resume previous run (if any):             $resume"
echo "Container dir:                            $container_dir"
echo "Scratch ('work') dir:                     $work_dir"
echo "Config 'profile' argument:                $profile_opt"
echo "Config file argument:                     $config_opt"
[[ -n "$config_file" ]] && echo "Additional config file:                       $config_file"
[[ "$IS_SLURM" = true ]] && slurm_resources
set_threads "$IS_SLURM"

# ==============================================================================
#                               RUN
# ==============================================================================
# Download the OSC config file
if [[ ! -f "$OSC_CONFIG" ]]; then
    log_time "Downloading the mcic-scripts Nextflow OSC config file to $OSC_CONFIG..."
    wget -q -O "$OSC_CONFIG" "$OSC_CONFIG_URL"
fi

# Prepare the samplesheet
log_time "Preparing the samplesheet $samplesheet with 'bactopia prepare'..."
runstats bactopia prepare --path "$indir" --species "$species" > "$samplesheet"
log_time "Printing the first rows of the sample sheet ($(wc -l <"$samplesheet") rows total):"
head -n 3 "$samplesheet"

# Run Bactopia - main workflow
log_time "Running the main Bactopia workflow..."
runstats $TOOL_BINARY --wf bactopia \
    --outdir "$outdir" --run_name "$run_name" \
    --samples "$samplesheet" \
    --species "$species" \
    --shovill_assembler "$assembler" \
    $annot_opt \
    $amr_organism_opt \
    --skip_qc \
    --singularity_cache "$container_dir" \
    $conda_dir_opt \
    --max_cpus $MAX_CPUS \
    --max_time $MAX_TIME \
    --max_memory $MAX_MEM \
    --max_retry $MAX_RETRY \
    -qs $QUEUE_SIZE \
    -w "$work_dir" \
    $profile_opt \
    $config_opt \
    $resume_opt \
    -ansi-log false \
    $more_opts

#? Other Bactopia options
# --datasets_cache      [string]  Directory where downloaded datasets should be stored. [default: <BACTOPIA_DIR>/data/datasets]
# --min_contig_len      [integer] Minimum contig length <0=AUTO> [default: 500]
# --min_contig_cov      [integer] Minimum contig coverage <0=AUTO> [default: 2]

# List the output
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
