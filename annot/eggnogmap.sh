#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=6:00:00
#SBATCH --cpus-per-task=12
#SBATCH --mem=48G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=eggnogmap
#SBATCH --output=slurm-eggnogmap-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run EggNOGmapper to functionally annotate proteins"
SCRIPT_VERSION="2025-09-17"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=emapper.py
TOOL_NAME=EggNOGmapper
TOOL_DOCS=https://github.com/eggnogdb/eggnog-mapper/wiki/eggNOG-mapper-v2.1.5-to-v2.1.11
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                  # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/conda/eggnog-mapper_2.1.13
container_url=
container_dir="$HOME/containers"
container_path=

# Constants - parameters
INPUT_TYPE=proteins             # Assume a protein (rather than nucleotide) FASTA

# Parameter defaults
db_dir=/fs/ess/PAS0471/refdata/eggnog/2025-09
search_method=diamond           # Also the EggNOGmapper default
go_evidence="non-electronic"    # Also the EggNOGmapper default
sensmode="more-sensitive"       # EggNOGmapper default is 'sensitive'
tax_scope="auto"                # Also the EggNOGmapper default


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
      sbatch $0 -i proteins.faa -o results/eggnogmapper
    
REQUIRED OPTIONS:
  -i/--infile         <file>  A FASTA file with protein sequences (proteome)
  -o/--outdir         <dir>   Output dir (will be created if needed)
    
OTHER KEY OPTIONS:
  --db_dir            <dir>   Pre-downloaded eggNOGmapper database dir          [default: $db_dir]
  --out_prefix        <str>   Output prefix, e.g. a genome ID                   [default: basename of protein file]
  --tax_scope         <str>   Taxonomic scope (see eggNOGmapper docs)           [default: 'auto']
  --search_method     <str>   'diamond', 'mmseqs', or 'hmmer'                   [default: 'diamond']
  --sensmode          <str>   Diamond sensitivity                               [default: 'more-sensitive']
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

HARDCODED PARAMETERS:
- This script is set up to work with a protein FASTA file;
    whereas it is also possible to run EggNOGmapper with a nucleotide FASTA file.

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
db_dir=
out_prefix=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --db_dir )          shift && db_dir=$1 ;;
        --out_prefix )      shift && out_prefix=$1 ;;
        --search_method )   shift && search_method=$1 ;;
        --sensmode )        shift && sensmode=$1 ;;
        --tax_scope )       shift && tax_scope=$1 ;;
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
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -d "$db_dir" ]] && die "Input EggNOGmapper DB dir $db_dir does not exist"

# Other variables
if [[ -z "$out_prefix" ]]; then
    prot_basename=$(basename "$infile")
    out_prefix=${prot_basename%.*}
fi

if [[ "$IS_SLURM" == true ]]; then
    scratch_dir="$PFSDIR"
    temp_dir="$PFSDIR"/tmp
    tempdir_arg="--scratch_dir $scratch_dir --temp_dir $temp_dir"
else
    temp_dir="$outdir"/tmp
    tempdir_arg="--temp_dir $temp_dir"
fi

# Get nr of genes in the input
ngenes_in=$(grep -c "^>" "$infile")

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR" "$temp_dir"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input file:                               $infile"
echo "Output dir:                               $outdir"
echo "Nr of entries (genes) in the input file:  $ngenes_in"
echo "eggNOGmapper database dir:                $db_dir"
echo "Output prefix:                            $out_prefix"
echo "Search method:                            $search_method"
echo "DIAMOND sensitivity:                      $sensmode"
echo "Taxonomic scope:                          $tax_scope"
echo "Scratch and temp dir argument:            $tempdir_arg"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    -i "$infile" \
    --itype "$INPUT_TYPE" \
    --data_dir "$db_dir" \
    --output_dir "$outdir" \
    --output "$out_prefix" \
    -m "$search_method" \
    --sensmode "$sensmode" \
    --tax_scope "$tax_scope" \
    --go_evidence "$go_evidence" \
    --cpu "$threads" \
    --override \
    $tempdir_arg \
    $more_opts

# Report
ngenes_out=$(grep -cv "^#" "$outdir"/*emapper.annotations)
ngenes_descrip=$(grep -v "^#" "$outdir"/*emapper.annotations | cut -f 8 | grep -cv "^-")
echo
echo "Nr of genes/entries in the input:         $ngenes_in"
echo "Nr of genes/entries in the output:        $ngenes_out"
echo "Nr of genes/entries with a description:   $ngenes_descrip"

#? Non-default options for Eggnogmapper
# --go_evidence all => default is to use only non-electronic terms (`non-electronic`), see https://github.com/eggnogdb/eggnog-mapper/wiki/eggNOG-mapper-v2.1.5-to-v2.1.8
# --go_evidence {experimental,non-electronic,all}
#                        Defines what type of GO terms should be used for annotation. experimental = Use only terms inferred from experimental evidence. non-electronic = Use only non-electronically curated terms
# --override => Overwrite existing output files

#? Other options for Eggnogmapper
# --pfam_realign denovo  Needs some HMMer server setup
# --list_taxa            List taxa available for --tax_scope/--tax_scope_mode, and exit
# --tax_scope            ....
# --resume               Resumes a previous emapper run, skipping results in existing output files.

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/*
final_reporting "$LOG_DIR"

# ==============================================================================
#                               INSTALLATION INFO
# ==============================================================================
# Downloading the EggNOGmapper database:
#! NOTE: Had to change two URLs in the download_eggnog_data.py scripts. Correct URLs:
#! See https://github.com/eggnogdb/eggnog-mapper/issues/571
#> BASE_URL = f'http://eggnog5.embl.de/download/emapperdb-{__DB_VERSION__}'        # JP: Changed this URL
#> EGGNOG_URL = f'http://eggnog5.embl.de/download/eggnog_5.0/per_tax_level'
#> EGGNOG_DOWNLOADS_URL = 'http://eggnog5.embl.de/#/app/downloads'
#> NOVEL_FAMS_BASE_URL = f'http://eggnog5.embl.de/download/novel_fams-{__NOVEL_FAMS_DB_VERSION__}' # JP: Changed this URL
# Then actually download:
#db_dir=/fs/ess/PAS0471/jelmer/refdata/eggnog/2025-09
#sbatch -A PAS0471 -t 120 --wrap="download_eggnog_data.py -y -f -F -P -M --data_dir $db_dir"

#> options:
#>   -h, --help       show this help message and exit
#>   -D               Do not install the diamond database (default: False)
#>   -F               Install the novel families diamond and annotation databases, required for "emapper.py -m novel_fams" (default: False)
#>   -P               Install the Pfam database, required for de novo annotation or realignment (default: False)
#>   -M               Install the MMseqs2 database, required for "emapper.py -m mmseqs" (default: False)
#>   -H               Install the HMMER database specified with "-d TAXID". Required for "emapper.py -m hmmer -d TAXID" (default: False)
#>   -d HMMER_DBS     Tax ID of eggNOG HMM database to download. e.g. "-H -d 2" for Bacteria. Required if "-H". Available tax IDs can be found at http://eggnog5.embl.de/#/app/downloads. (default: None)
#>   --dbname DBNAME  Tax ID of eggNOG HMM database to download. e.g. "-H -d 2 --dbname 'Bacteria'" to download Bacteria (taxid 2) to a directory named Bacteria (default: None)
#>   -y               assume "yes" to all questions (default: False)
#>   -f               forces download even if the files exist (default: False)
#>   -s               simulate and print commands. Nothing is downloaded (default: False)
#>   -q               quiet_mode (default: False)
#>   --data_dir       Directory to use for DATA_PATH. (default: None)
