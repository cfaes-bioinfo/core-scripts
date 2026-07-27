#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=resfinder
#SBATCH --output=slurm-resfinder-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run ResFinder to detect AMR genes and point mutations in a bacterial genome assembly"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=run_resfinder.py
TOOL_NAME=ResFinder
TOOL_DOCS=https://bitbucket.org/genomicepidemiology/resfinder
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                           # Use a 'conda' env or a Singularity 'container'
container_path=oras://community.wave.seqera.io/library/resfinder:4.7.2--93977212deab6a11
conda_path=
container_url=
dl_container=false
container_dir="$HOME/containers"

# Defaults - tool parameters
get_db=true                         # Download the database
point_mut=true                      # Include point mutations
acquired=true
min_cov=0.90                        # Coverage threshold for BLAST hits
min_id=0.90                         # Identity threshold for BLAST hits

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
    echo "      sbatch $0 -i assemblies/sample15.fna -o results/resfinder/sample15"
    echo "  - Loop over assemblies -- make sure to use a separate output dir for each:"
    echo "    NOTE: for some reason it may be necessary to 'sleep' in between, or ResFinder will crash!"
    echo "      for asm in result/assemblies/*fna; do"
    echo '          outdir=results/resfinder/$(basename "$asm" .fna)'
    echo '          sbatch mcic-scripts/bact/resfinder.sh -i "$asm" -o "$outdir"'
    echo "          sleep 10s"
    echo "      done"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i/--assembly   <file>      Input file: a nucleotide FASTA file with a genome assembly"
    echo "  -o/--outdir     <dir>       Output dir (use a separate dir per assembly)"
    echo "  --species       <str>       Species name -- see ResFinder docs for possible values"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --no_point_mut              Skip point-mutation-based resistance    [default: include]"
    echo "  --no_aqcuired               Skip aqcuired genes                     [default: include]"
    echo "  --min_cov           <num>   Coverage threshold                      [default: 0.90]"
    echo "  --min_id            <num>   Identity threshold                      [default: 0.90]"
    echo "  --db_dir                    Dir with/for ResFinder DBs              [default: <outdir>/dbs]"
    echo "  --dont_get_db               Don't download the ResFinder DBs        [default: download]"
    echo "  --opts              <str>   Quoted string with additional options for $TOOL_NAME"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --env_type               <str>   Use a Singularity container ('container') or a Conda env ('conda') [default: $env_type]"
    echo "                                NOTE: If no default '--container_url' or '--container_dir' is listed below,"
    echo "                                you'll have to provide one of these to run the script with a container."
    echo "  --container_url     <str>   URL to download the container from      [default: $container_url]"
    echo "                                A container will only be downloaded if an URL is provided with this option, or '--dl_container' is used"
    echo "  --container_dir     <str>   Dir to download the container to        [default: $container_dir]"
    echo "  --dl_container              Force a redownload of the container     [default: $dl_container]"
    echo "  --conda_env         <dir>   Full path to a Conda environment to use [default: $conda_path]"
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
source_function_script

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
infile=
outdir=
species=
db_dir=
opts=
version_only=false

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --assembly )   shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --species )         shift && species=$1 ;;
        --dont_get_db )     get_db=false ;;
        --db_dir )          shift && db_dir=$1 ;;
        --no_point_mut )    point_mut=false && point_arg="" ;;
        --no_aqcuired )     acquired=false && acquired_arg="" ;;
        --min_cov )         shift && readonly min_cov=$1 ;;
        --min_id )          shift && readonly min_id=$1 ;;
        --opts )            shift && opts=$1 ;;
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
#set -euo pipefail

# Load software
load_env "$conda_path" "$container_path" "$dl_container"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$species" ]] && die "No species specified, do so with --species" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ -n "$db_dir" && ! -d "$db_dir" ]] && die "DB dir $db_dir does not exist"
[[ "$get_db" == false && -z "$db_dir" ]] && die "You have to specify a DB dir with --db_dir when using --dont_get_db"

# Define outputs based on script parameters
LOG_DIR="$PWD"/"$outdir"/logs && mkdir -p "$LOG_DIR"
[[ -z "$db_dir" ]] && db_dir="$outdir"/dbs && mkdir -p "$db_dir"

# Make paths absolute since we have to move into the output dir
infile=$(realpath "$infile")
[[ ! "$outdir" =~ ^/ ]] && outdir="$PWD"/"$outdir"
[[ ! "$db_dir" =~ ^/ ]] && db_dir="$PWD"/"$db_dir"

# Define args
[[ "$point_mut" == true ]] && point_arg="--point"
[[ "$acquired" == true ]] && acquired_arg="--acquired"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Input genome assembly FASTA file:         $infile"
echo "Output dir:                               $outdir"
echo "Database dir:                             $db_dir"
echo "Species:                                  $species"
echo "Include point mutations:                  $point_mut"
echo "Include acquired genes:                   $acquired"
echo "Min. coverage threshold:                  $min_cov"
echo "Min. identity threshold:                  $min_id"
[[ -n $opts ]] && echo "Additional options for $TOOL_NAME:        $opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Download/update the database
if [[ "$get_db" == true ]]; then
    log_time "Downloading the ResFinder database into $db_dir/resfinder_db ..."
    cd "$db_dir" || die "Can't move to DB dir $db_dir"
    [[ -d resfinder_db ]] && rm -r resfinder_db
    
    git clone https://bitbucket.org/genomicepidemiology/resfinder_db
    cd resfinder_db || exit 1
    python3 INSTALL.py #&> "$LOG_DIR"/resfinder_db.log

    if [[ "$point_mut" == true ]]; then
        log_time "Downloading the PointFinder database into $db_dir/pointfinder_db ..."
        cd "$db_dir" || die "Can't move to DB dir $db_dir"
        [[ -d pointfinder_db ]] && rm -r pointfinder_db

        git clone https://bitbucket.org/genomicepidemiology/pointfinder_db
        cd pointfinder_db || exit 1
        python3 INSTALL.py #&> "$LOG_DIR"/pointfinder_db.log
    fi
fi

# Move the output dir
log_time "Moving into the output dir $outdir..."
cd "$outdir" || die "Can't move to output dir $outdir"

log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --inputfasta "$infile" \
    --outputPath "$outdir" \
    --species "$species" \
    --min_cov "$min_cov" \
    --threshold "$min_id" \
    --db_path_res "$db_dir"/resfinder_db \
    --db_path_point "$db_dir"/pointfinder_db \
    $acquired_arg \
    $point_arg \
    $opts

log_time "Listing files in the output dir:"
ls -lh
final_reporting "$LOG_DIR"
