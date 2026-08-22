#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=36:00:00
#SBATCH --cpus-per-task=20
#SBATCH --mem=80G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=spades
#SBATCH --output=slurm-spades-%j.out

#TODO - Consider automatically emptying outdir if it exists,
#TODO     or to switch to continue -- Spades fails when the outdir is not empty

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Assemble a (meta)genome or transcriptome with SPAdes"
SCRIPT_VERSION="2024-10-01"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=spades.py
TOOL_NAME=SPAdes
TOOL_DOCS=https://github.com/ablab/spades
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                           # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/jelmer/conda/spades
container_path=
container_url=
dl_container=false
container_dir="$HOME/containers"
version_only=false                 # When true, just print tool & script version info and exit

# Constants - only used in SLURM jobs
# In some cases, spades needs more than the alotted 1TB in $TMPDIR
SCRATCH_TMPDIR="$PFSDIR"
NODE_TMPDIR="$TMPDIR"

# Parameter defaults
use_node_tmpdir=false
kmer_sizes="auto" && kmer_arg=""
careful=false && careful_arg=""
continue=false                      # Restart run
strandedness="rf"                   # Only applies for mode 'rna'
mem=4                               # Only applies when not running a SLURM job

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "\n                          $0"
    echo "      (v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)"
    echo "        =============================================================="
    echo "DESCRIPTION:"
    echo "  $DESCRIPTION"
    echo
    echo "USAGE / EXAMPLE COMMANDS:"
    echo "  - Basic usage example:"
    echo "      sbatch $0 -i results/trim/sampleA_R1.fastq.gz -o results/spades/sampleA"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -o/--outdir         <dir>   Output dir - NOTE: This dir should either not yet exist or be empty"
    echo "To specify the input, use one of the following options:"
    echo "  -i/--R1             <file>  Input R1 (forward) FASTQ file (the name of the R2 file will be inferred)"
    echo "  --indir             <dir>   Dir with gzipped FASTQ files"
    echo "  --fofn              <file>  File of file names (fofn): one line per input R1 FASTQ file"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --mode              <str>   Spades run mode                             [default: default Spades]"
    echo "                                Possible values: 'isolate', 'meta', 'metaplasmid, 'metaviral', 'plasmid', 'rna', 'rnaviral'"
    echo "  --kmer_sizes        <str>   Comma-separated list of kmer sizes          [default: 'auto' => Spades default of auto-selecting kmer sizes]"
    echo "  --strandedness      <str>   Strandedness for RNAseq libraries     [default: 'rf' (reverse)]"
    echo "                                Options: 'rf'/'reverse', 'fr'/'forward', or 'unstranded'"
    echo "  --careful                   Run in 'careful' mode (small genomes only)  [default: don't run in careful mode]"
    echo "  --continue                  Resume an interrupted run                   [default: start anew]"
    echo "  --use_node_tmpdir           Instead of the OSC scratch temp dir '$PFSDIR', use the node temp dir '$TMPDIR'"
    echo "                                This is for Spades' '--tmp-dir' argument."
    echo "                                However, note that sometimes, there isn't enough space on the '$TMPDIR'..."
    echo "  --more_opts         <str>   Quoted string with additional options for $TOOL_NAME"
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
        wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script"
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
R1=
indir=
fofn=
outdir=
mode= && mode_arg=
strand_arg=
more_opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1=$1 ;;
        --indir )           shift && indir=$1 ;;
        --fofn )            shift && fofn=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --kmer_sizes )      shift && kmer_sizes=$1 ;;
        --mode )            shift && mode=$1 ;;
        --strandedness)     shift && strandedness=$1 ;;
        --careful )         careful=true ;;
        --continue )        continue=true ;;
        --use_node_tmpdir ) use_node_tmpdir=true ;; 
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

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$R1" && -z "$indir" && -z "$fofn" ]] && die "Please specify either an R1 input file with -i, an input dir with -I, or an input FOFN with -f"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -n "$R1" && ! -f "$R1" ]] && die "Input file R1 $R1 does note exist"
[[ -n "$fofn" && ! -f "$fofn" ]] && die "Input FOFN $fofn does note exist"
[[ -n "$indir" && ! -f "$indir" ]] && die "Input dir $indir does note exist"

# Define outputs based on script parameters
mkdir -p "$outdir"
LOG_DIR="$outdir"/logs

# Additional variables
if [[ "$IS_SLURM" == true ]]; then
    # Memory - convert MB memory to GB (and subtract 1)
    mem=$(( (SLURM_MEM_PER_NODE / 1000) - 1))
    # Have also used the below, following https://github.com/ablab/spades/issues/494
    # mem=$(( (SLURM_MEM_PER_NODE / 1000) + 1500))
    
    # Determine what to use as the temporary directory
    if [[ "$use_node_tmpdir" = true ]]; then
        TMPDIR_FINAL="$NODE_TMPDIR"
    else
        TMPDIR_FINAL="$SCRATCH_TMPDIR"
    fi
    tmpdir_arg="--tmp-dir=$TMPDIR_FINAL"
fi

# Build some arguments to pass to SPAdes
[[ "$mode" != "" ]] && mode_arg="--$mode"
[[ "$careful" = true ]] && careful_arg="--careful"
[[ "$kmer_sizes" != "auto" ]] && kmer_arg="-k $kmer_sizes"

if [[ "$mode" = rna ]]; then
    if [[ "$strandedness" = "unstranded" ]]; then
        strand_arg=""
    elif [[ "$strandedness" = "reverse" ]]; then
        strand_arg="--ss rf"
    elif [[ "$strandedness" = "forward" ]]; then
        strand_arg="--ss fr"
    else
        strand_arg="--ss $strandedness"
    fi
fi

# Input file arg
if [[ "$R1" != "" ]]; then
    # Infer R2 filename
    file_ext=$(basename "$R1" | sed -E 's/.*(.fastq.gz|.fq.gz)/\1/')
    R1_suffix=$(basename "$R1" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
    R2_suffix=${R1_suffix/1/2}
    R2=${R1/$R1_suffix/$R2_suffix}
    infile_arg="--pe1-1 $R1 --pe1-2 $R2"

    [[ "$R1" = "$R2" ]] && Die "Input file R1 and R2 are the same: $R1"
    [[ ! -f "$R2" ]] && Die "Input file R2 ($R2) does not exist"
else
    yaml="$outdir"/input_filenames.yml
    infile_arg="--dataset $yaml"
fi

# If an input dir was provided, create a FOFN
if [[ -n "$indir" ]]; then
    log_time "Preparing a FOFN from files in the input dir..."
    fofn="$outdir"/input_filenames.txt
    ls "$indir"/*_R1*q.gz > "$fofn"
    log_time "Number of input files:            $(grep -c "." "$fofn")"
fi

# ==============================================================================
#                               REPORT
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All arguments to this script:     $all_opts"
[[ -n "$mode" ]] && echo "Running mode:                     $mode"
[[ -n "$R1" ]] && echo "Input FASTQ file - R1:            $R1"
[[ -n "$R2" ]] && echo "Input FASTQ file - R2:            $R2"
[[ "$mode" == "rna" ]] && echo "Strandedness / strand argument:   $strandedness / $strand_arg"
echo "Output dir:                       $outdir"
echo "Kmer size(s):                     $kmer_sizes"
echo "Using 'careful' setting:          $careful"
echo "Continuing a previous run:        $continue"
echo "Memory in GB:                     $mem"
[[ $tmpdir_arg != "" ]] && echo "Temp dir argument:                $tmpdir_arg"
[[ $more_opts != "" ]] && echo "Other options for Spades:         $more_opts"
echo "Input file argument:              $infile_arg"
log_time "Listing the input file(s):"
[[ -n "$R1" ]] && ls -lh "$R1" "$R2"
[[ -n "$fofn" ]] && cat "$fofn" | xargs -I{} ls -lh {}
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                        PREPARE INPUT FILE YAML
# ==============================================================================
if [[ -n "$fofn" ]]; then
    log_time "Now creating the input YAML file..."

# Create template file
    cat > "$yaml".tmp1 <<'_EOF'
    [
        {
            orientation: "fr",
            type: "paired-end",
            right reads: [
            R2_reads
            ],
            left reads: [
            R1_reads
            ]
        },
    ]
_EOF

    # Make dirs absolute if needed
    sed "/^\//d" "$fofn" | sed -E "s@^@$PWD/@" > "$yaml".modlist
    sed -n "/^\//p" "$fofn" >> "$yaml".modlist   # Paths that were already absolute

    # Replace placeholder strings with filenames
    R1=$(sed -e 's/^/"/' -e 's/$/"/' "$yaml".modlist | sed 's/$/,/')
    R2=$(sed -e 's/^/"/' -e 's/$/"/' "$yaml".modlist | sed 's/$/,/' | sed 's/_R1/_R2/')
    awk -v r="$R1" '{gsub(/R1_reads/,r)}1' "$yaml".tmp1 > "$yaml".tmp2
    awk -v r="$R2" '{gsub(/R2_reads/,r)}1' "$yaml".tmp2 > "$yaml"

    # Remove temporary files
    rm "$yaml".tmp1 "$yaml".tmp2 "$yaml".modlist

    log_time "Printing the contents of the input YAML file:"
    cat "$yaml"
    echo "=========================================================================="
fi

# ==============================================================================
#                               RUN
# ==============================================================================
# Run SPAdes
if [ "$continue" = false ]; then
    log_time "Running $TOOL_NAME..."
    runstats $TOOL_BINARY \
        $infile_arg \
        -o "$outdir" \
        --threads "$threads" \
        --memory "$mem" \
        ${kmer_arg} \
        ${mode_arg} \
        ${strand_arg} \
        ${careful_arg} \
        ${tmpdir_arg} \
        ${more_opts}
else
    log_time "Resuming a previous SPAdes run..."
    runstats $TOOL_BINARY \
        -o "$outdir" \
        --continue
fi

# Only now make the log dir (if we make it before running SPAdes, it will complain)
mkdir -p "$LOG_DIR"
load_env "$conda_path" "$container_path" "$dl_container"

log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
