#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=32:00:00
#SBATCH --cpus-per-task=15
#SBATCH --mem=60G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=braker3
#SBATCH --output=slurm-braker3-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Braker3 to annotate a genome assembly.
As 'evidence' for annotation, provide RNAseq data of the same species and/or
protein data of the same or related species."
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=braker.pl
TOOL_NAME=Braker3
TOOL_DOCS=https://github.com/Gaius-Augustus/BRAKER
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                      # Use a 'conda' env or a Singularity 'container'
conda_path=
container_path=/fs/ess/PAS0471/containers/braker3.sif
container_url=
dl_container=false
container_dir="$HOME/containers"
version_only=false                 # When true, just print tool & script version info and exit

# Defaults - tool parameters etc
rebuild_container=false            # If true, pulls and builds (from Docker) latest Braker container
is_fungus=false

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
    echo "  - Provide both RNAseq and protein data:"
    echo "    sbatch $0 -i results/genome.fa -o results/braker --rnaseq_fqdir data/rnaseq --prot_file data/ref/proteins.faa --species homo_sapiens"
    echo "  - Provide only protein data, and use the '--fungus' option:"
    echo "    sbatch $0 -i results/genome.fa -o results/braker --prot_file data/ref/proteins.faa --species candida_albicans --fungus"
    echo "  - Provide RNAseq data via SRA IDS: the corresponding FASTQ files will be downloaded"
    echo "    sbatch $0 -i results/genome.fa -o results/braker --rnaseq_sra_ids SRR5506722,SRR6942483,SRR21195554 --species homo_sapiens"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--assembly       <file>  Input assembly nucleotide FASTA"
    echo "  -o/--outdir         <dir>   Output dir (will be created if needed)"
    echo "  --species           <str>   Species name (without space, e.g. 'homo_sapiens')"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --rnaseq_fqdir      <dir>   Directory with RNAseq FASTQ files"
    echo "                              NOTE: FASTQs should be unzipped, and end in '_1.fastq' / '_2.fastq' for R1/R2 reads"
    echo "  --rnaseq_sra_ids    <str>   Comma-separated list of RNAseq SRA IDs, e.g. 'SRR5506722,SRR6942483,SRR21195554'"
    echo "  --prot_file         <file>  FASTA file with reference proteins. For info on how to create this file:"
    echo "                              https://github.com/gatech-genemark/ProtHint#protein-database-preparation"
    echo "  --fungus                    Use a fungus-specific annotation model implemented in Braker"
    echo "  --rebuild_container         Force a redownload of the container     [default: $rebuild_container]"
    echo "                                This will pull from docker://teambraker/braker3:latest, and would therfore update to the latest version"
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
infile=
species=
outdir=
prot_file= && prot_opt=
rnaseq_fqdir= && rnaseq_opt=
rnaseq_sra_ids=
fungus_opt=
more_opts=
threads=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )         shift && infile=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        --species )             shift && species=$1 ;;
        --prot_file )           shift && prot_file=$1 ;;
        --rnaseq_fqdir )        shift && rnaseq_fqdir=$1 ;;
        --rnaseq_sra_ids )      shift && rnaseq_sra_ids=$1 ;;
        --fungus )              is_fungus=true ;;
        --more_opts )           shift && more_opts=$1 ;;
        --env_type )                 shift && env_type=$1 ;;
        --rebuild_container )   rebuild_container=true ;;
        --container_dir )       shift && container_dir=$1 ;;
        --container_url )       shift && container_url=$1 && dl_container=true ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version )             version_only=true ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
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

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"

# Make input paths absolute
infile=$(realpath "$infile")
[[ -n "$prot_file" ]] && prot_file=$(realpath "$prot_file")
[[ -n "$rnaseq_fqdir" ]] && rnaseq_fqdir=$(realpath "$rnaseq_fqdir")

# Protein sequence file
[[ -n "$prot_file" ]] && prot_opt="--prot_seq=$prot_file"

# RNAseq data argument
if [[ -n "$rnaseq_fqdir" ]]; then
    fq_ids=$(ls "$rnaseq_fqdir"/*fastq | xargs -n1 basename | sed 's/_[12].fastq//' |
             sort | uniq | tr "\n" "," | sed 's/,$/\n/')
    rnaseq_opt="--rnaseq_sets_dirs=$rnaseq_fqdir --rnaseq_sets_ids=$fq_ids"
elif [[ -n "$rnaseq_sra_ids" ]]; then
    rnaseq_opt="--rnaseq_sets_ids=$rnaseq_sra_ids"
fi

# Augustus config dir
augustus_config_dir="$PWD"/"$outdir"/augustus_config
augustus_config_opt="--AUGUSTUS_CONFIG_PATH=$augustus_config_dir"

# Fungus option
[[ "$is_fungus" == true ]] && fungus_opt="--fungus"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input assembly file:                      $infile"
echo "Output dir:                               $outdir"
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

# Copy the Augustus config dir from the container
# This is needed because Braker will otherwise try to write inside the container
log_time "Copying the Augustus config dir from the container..."
singularity exec -B "$PWD":"$PWD" "$container_path" \
    cp -r /opt/Augustus/config/ "$augustus_config_dir"
#    cp -r /usr/share/augustus/config/ "$augustus_config_dir"

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --workingdir="$outdir" \
    --genome="$infile" \
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

# Final reporting
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"
