#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=30
#SBATCH --mem=100G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=kraken
#SBATCH --output=slurm-kraken-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Kraken2 to assign taxonomy to sequences in a FASTA/FASTQ/pair of FASTQ file(s)"
SCRIPT_VERSION="2026-07-27"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=kraken2
TOOL_NAME=Kraken2
TOOL_DOCS=https://github.com/DerrickWood/kraken2
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=conda                  # Use a 'conda' env or a Singularity 'container'
conda_path=/fs/ess/PAS0471/conda/kraken_2.1.6 # Also includes Krakentools
container_url=
container_dir="$HOME/containers"
container_path=

# Defaults - tool parameters
min_conf=0.15                       # Following https://www.microbiologyresearch.org/content/journal/mgen/10.1099/mgen.0.000949
min_hitgroups=3                     # Following https://www.nature.com/articles/s41596-022-00738-y
write_classif=false                 # Don't write output file(s) with classified reads
write_unclassif=false               # Don't write output file(s) with unclassified reads
use_ram=true                        # Load Kraken db into memory
single_end=false                    # Assume paired-end reads, if the input is FASTQ

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
      sbatch $0 -i data/S1_R1.fastq.gz -o results/kraken --db /fs/ess/PAS0471/jelmer/refdata/kraken/std
    
REQUIRED OPTIONS:
  -i/--infile        <file>  Input sequence file (FASTA, single-end FASTQ, or R1 from paired-end FASTQ)
                                - If an R1 paired-end FASTQ file is provided, the name of the R2 file will be inferred
                                - FASTA files should be unzipped; FASTQ files should be gzipped
  -o/--outdir        <dir>   Output dir (will be created if needed)
  --db               <dir>   Directory with an existing Kraken database
                               - A few databases are available at: /fs/ess/PAS0471/jelmer/refdata/kraken
                               - Kraken databases can be downloaded from: https://benlangmead.github.io/aws-indexes/k2
                               - Finally, you can use 'mcic-scripts/meta/kraken-build.sh' to create a database
    
OTHER KEY OPTIONS:
  --confidence       <num>   Confidence required for assignment: number between 0 and 1            [default: $min_conf]
  --min-hit-groups   <int>   Minimum nr of hit groups required an assignment                       [default: $min_hitgroups]
  --memory-mapping           Don't load the full database into RAM memory                          [default: load into memory]
                               - Considerably slower, but useful/needed with very large databases
  --classified-out           Write 'classified' sequences to file in '<outdir>/classified' dir     [default: don't write]
                               NOTE: only implemented for PE FASTQ files
  --unclassified-out         Write 'unclassified' sequences to file in '<outdir>/unclassified' dir [default: don't write]
                                NOTE: only implemented for PE FASTQ files
  --single-end               FASTQ files are single-end                                            [default: paired-end]
  --more_opts         <str>  Quoted string with one or more additional options
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
    
TOOL DOCUMENTATION:
  $TOOL_DOCS
"
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
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -f "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -f "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script_name"
        fi
        source "$function_script_name"
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
R1_in= && R2_in=
outdir=
db=
conf_opt=
hitgroup_opt=
classif_opt=
unclassif_opt=
mem_opt=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infile )     shift && infile=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        --db | --db-dir )   shift && db=$1 ;;
        --confidence )      shift && min_conf=$1 ;;
        --min-hit-groups )  shift && min_hitgroups=$1 ;;
        --single-end )      single_end=true ;;
        --classified-out )  write_classif=true ;;
        --unclassified-out ) write_unclassif=true ;;   
        --memory-mapping )  use_ram=false ;;
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
[[ -z "$db" ]] && die "No Kraken database dir specified, do so with -d/--db" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ ! -d "$db" ]] && die "Kraken database dir $db does not exist"

# Other prep based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
[[ "$use_ram" == false ]] && mem_opt="--memory-mapping "
[[ -n "$min_conf" ]] && conf_opt="--confidence $min_conf "
[[ -n "$min_hitgroups" ]] && hitgroup_opt="--minimum-hit-groups $min_hitgroups "

# Make sure input file argument is correct based on file type 
if [[ "$infile" =~ \.fa?s?t?q.gz$ ]]; then
    R1_in="$infile"
    R1_basename=$(basename "$R1_in" | sed -E 's/\.fa?s?t?q\.gz//')
    R1_suffix=$(echo "$R1_basename" | sed -E 's/.*(_R?[12]).*/\1/')
    
    if [[ "$single_end" == false ]]; then
        file_type=pe
        R2_suffix=${R1_suffix/1/2}
        R2_in=$(echo "$R1_in" | sed -E "s/${R1_suffix}([._])/${R2_suffix}\1/")
        
        sample_id=${R1_basename/"$R1_suffix"/}
        infile_opt="--gzip-compressed --paired $R1_in $R2_in"

        [[ ! -f "$R2_in" ]] && die "R2 file ($R2_in) does not exist"
        [[ "$R1_in" == "$R2_in" ]] && die "R1 file ($R1_in) is the same as R2 file ($R2_in)"

        if [[ "$write_classif" == true ]]; then
            classif_opt="--classified-out $outdir/classified/$sample_id#.fastq "
        fi
        if [[ "$write_unclassif" == true ]]; then
            unclassif_opt="--unclassified-out $outdir/unclassified/$sample_id#.fastq "
        fi
    else
        file_type=se
        sample_id=$R1_basename
        infile_opt="--gzip-compressed $R1_in"

        if [[ "$write_classif" == true ]]; then
            classif_opt="--classified-out $outdir/classified/$sample_id.fastq "
        fi
        if [[ "$write_unclassif" == true ]]; then
            unclassif_opt="--unclassified-out $outdir/unclassified/$sample_id.fastq "
        fi
    
    fi
elif [[ "$infile" =~ \.fn?a?s?t?a$ ]]; then
    file_type=fasta
    infile_basename=$(basename "$infile")
    sample_id=${infile_basename%%.*}
    infile_opt="$infile"

    if [[ "$write_classif" == true ]]; then
        classif_opt="--classified-out $outdir/classified/$sample_id.fa "
    fi
    if [[ "$write_unclassif" == true ]]; then
        unclassif_opt="--unclassified-out $outdir/unclassified/$sample_id.fa "
    fi
else
    die "Unknown input file type"
fi

# Define output text files
outfile_main="$outdir"/"$sample_id".main.txt
outfile_report="$outdir"/"$sample_id".report.txt

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Output dir:                               $outdir"
echo "Input file type:                          $file_type"
echo "Kraken database dir:                      $db"
echo "Write classified reads?                   $write_classif"
echo "Write unclassified reads?                 $write_unclassif"
[[ -n $min_conf ]] && echo "Minimum confidence:                       $min_conf"
[[ -n $min_hitgroups ]] && echo "Minimum nr of hit groups:                 $min_hitgroups"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
[[ -n $R1_in ]] && ls -lh "$R1_in"
[[ -n $R2_in ]] && ls -lh "$R2_in"
[[ -z $R1_in && -n $infile ]] && ls -lh "$infile"
log_time "Listing the k2d database file(s):"
ls -lh "$db"/*k2d
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
# Create output dirs
[[ "$write_classif" = true ]] && mkdir -p "$outdir"/classified
[[ "$write_unclassif" = true ]] && mkdir -p "$outdir"/unclassified
mkdir -p "$outdir"/logs

# Run Kraken
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    ${more_opts}--threads "$threads" \
    ${mem_opt}${hitgroup_opt}${conf_opt}--report-minimizer-data \
    ${classif_opt}--db "$db" \
    ${unclassif_opt}--report "$outfile_report" \
    ${infile_opt}> "$outfile_main"

# Rename and zip FASTQ files - only implemented for PE FASTQ
if  [[ "$file_type" = "pe" ]]; then
    if [[ "$write_classif" = true ]]; then
        echo -e "\n# Zipping FASTQ files with classified reads..."
        mv "$outdir"/classified/"$sample_id"_1.fastq "$outdir"/classified/"$sample_id"_R1.fastq
        gzip -f "$outdir"/classified/"$sample_id"_R1.fastq

        mv "$outdir"/classified/"$sample_id"_2.fastq "$outdir"/classified/"$sample_id"_R2.fastq
        gzip -f "$outdir"/classified/"$sample_id"_R2.fastq
    fi
    if [[ "$write_unclassif" = true ]]; then
        echo -e "\n# Zipping FASTQ files with unclassified reads..."
        mv "$outdir"/unclassified/"$sample_id"_1.fastq "$outdir"/unclassified/"$sample_id"_R1.fastq
        gzip -f "$outdir"/unclassified/"$sample_id"_R1.fastq

        mv "$outdir"/unclassified/"$sample_id"_2.fastq "$outdir"/unclassified/"$sample_id"_R2.fastq
        gzip -f "$outdir"/unclassified/"$sample_id"_R2.fastq
    fi
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing the Kraken output reports:"
ls -lh "$outfile_main" "$outfile_report"
final_reporting "$LOG_DIR"
