#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=cutadapt
#SBATCH --output=slurm-cutadapt-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Run Cutadapt to remove (metabarcoding) PRIMERS for one FASTQ file
(single-end) or a pair of FASTQ files (paired-end).
The script will also compute and use the reverse complements of the specified primers."
SCRIPT_VERSION="2026-08-22"
SCRIPT_AUTHOR="Jelmer Poelstra"
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=cutadapt
TOOL_NAME=Cutadapt
TOOL_DOCS=https://cutadapt.readthedocs.io/en/stable
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container                     # Use a 'conda' env or a Singularity 'container'
conda_path=oras://community.wave.seqera.io/library/cutadapt:5.2--7e96173061760bf9
container_dir="$HOME/containers"
container_url=
container_path=

# Defaults - tool parameters
single_end=false                # Assume that reads are paired-end
discard_untrimmed=true          # Remove untrimmed (= no primer) reads
save_untrimmed=false            # Save untrimmed reads to separate files
pair_filter=any                 # Read removal strategy for paired-end sequences
overlap=10                      # Minimum primer-to-read overlap length for adapter removal

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "
                        $0
    v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL)
            =================================================

DESCRIPTION:
$DESCRIPTION
    
USAGE / EXAMPLE COMMANDS:
  - Basic usage example:
      sbatch $0 -i data/sample1_R1.fastq.gz -o results/cutadapt -f GAGTGYCAGCMGCCGCGGTAA -r ACGGACTACNVGGGTWTCTAAT
  - Using a file with multiple primer sequences:
      sbatch $0 -i data/sample1_R1.fastq.gz -o results/cutadapt --primer_file metadata/primers.txt

REQUIRED OPTIONS:
  -i/--R1             <file>  Input R1 FASTQ/FASTA file
                              (R2 filename will be inferred for paired-end)
  -o/--outdir         <dir>   Output dir (will be created if needed)

You also have to specify primers, and there are two ways of doing so:
(1) with '-f' and '-r': e.g. '-f GAGTGYCAGCMGCCGCGGTAA -r ACGGACTACNVGGGTWTCTAAT'
(2) with '--primer_file' (use the latter if you have multiple primer pairs)
In either case, the script will also compute and use the reverse complements of
the specified primers.

  -f/--primer_f       <str>   Forward primer sequence (must combine with '-r')
  -r/--primer_r       <str>   Reverse primer sequence (must combine with '-f')
  --primer_file       <file>  File with primer sequences, one pair per line,
                              separated by a space (*alternative* to -f & -r)

OTHER KEY OPTIONS:
  --single_end                Sequences are single-end                          [default: $single_end]
  --overlap           <int>   Minimum overlap length for adapter removal        [default: $overlap]
  --keep_untrimmed            Keep untrimmed sequences                          [default: discard these]
                              (i.e. sequences without the specified primers)
  --save_untrimmed            Save untrimmed sequences to separate file(s)                              
  --pair_filter       <str>   Read removal strategy for paired-end sequences:   [default: $pair_filter]
                              - 'any':  remove read pair if either read does not
                                        contain the primer
                              - 'both': remove read pair only if both reads do
                                        not contain the primer                            
  --more_opts         <str>   Quoted string with additional argument(s) for
                              $TOOL_NAME

UTILITY OPTIONS:
  --env_type          <str>   Use a Singularity container ('container')         [default: $env_type]
                              or a Conda environment ('conda') 
  --conda_env         <dir>   Full path to a Conda environment to use           [default: $conda_path]
  --container_url     <str>   URL to download the container from                [default: $container_url]
  --container_dir     <str>   Dir to download the container to                  [default: $container_dir]
  --container_path    <file>  Pre-existing Singularity container image file (.sif) to use
  -h/--help                   Print this help message and exit
  -v/--version                Print the version of this script and of $TOOL_NAME

TOOL DOCUMENTATION: $TOOL_DOCS
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
version_only=false  # When true, just print tool & script version info and exit
R1=
outdir=
untrimmed_opt=
primer_f=
primer_r=
primer_file=
primer_opt=
more_opts=
threads=
container_path=

# Parse command-line args
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --R1 )         shift && R1=$1 ;;
        -o | --outdir )     shift && outdir=$1 ;;
        -f | --primer_f )   shift && primer_f=$1 ;;
        -r | --primer_r )   shift && primer_r=$1 ;;
        --primer_file )     shift && primer_file=$1 ;;
        --pair_filter )     shift && pair_filter=$1 ;;
        --keep_untrimmed )  discard_untrimmed=false ;;
        --save_untrimmed )  save_untrimmed=true ;;
        --single_end )      single_end=true ;;
        --more_opts )       shift && more_opts=$1 ;;
        --overlap )         shift && overlap=$1 ;;
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
load_env "$env_type" "$conda_path" "$container_path" "$container_dir" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$R1" ]] && die "No input file specified, do so with -i/--R1" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! -f "$R1" ]] && die "Input file $R1 does not exist"

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs && mkdir -p "$LOG_DIR"
indir=$(dirname "$R1")
R1_base=$(basename "$R1")
file_ext=$(echo "$R1_base" | sed -E 's/.*(.fastq|.fq|.fastq.gz|.fq.gz)$/\1/')
R1_suffix=$(basename "$R1" "$file_ext" | sed -E "s/.*(_R?1)_?[[:digit:]]*/\1/")
R1_filename=$(basename "$R1")
sample_id=$(basename "$R1" "$file_ext" | sed -E "s/${R1_suffix}_?[[:digit:]]*//")
if [[ "$single_end" == false ]]; then
    log_time "Assuming that reads are paired-end: inferring the R2 filename..."
    R2_suffix=${R1_suffix/1/2}
    R2="$indir"/${R1_base/$R1_suffix/$R2_suffix}
    R2_filename=$(basename "$R2")
    [[ ! -f "$R2" ]] && die "Input FASTQ file $R2 not found"
fi
if [[ "$save_untrimmed" == true ]]; then
    mkdir -p "$outdir"/untrimmed
    untrimmed_R1=$(echo "$outdir"/untrimmed/"$R1_filename" | sed 's/.fastq.gz/_untrimmed.fastq.gz/')
    untrimmed_opt="--untrimmed-output $untrimmed_R1"
    
    if [[ "$single_end" == false ]]; then
        untrimmed_R2=$(echo "$outdir"/untrimmed/"$R2_filename" | sed 's/.fastq.gz/_untrimmed.fastq.gz/')
        untrimmed_opt+=" --untrimmed-paired-output $untrimmed_R2"
    fi
    
    elif [[ "$discard_untrimmed" == true ]]; then
        untrimmed_opt="--discard-untrimmed"
fi

# Check
[[ "$indir" == "$outdir" ]] && die "Input dir should not be the same as output dir ($indir)"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo "Input (R1) FASTQ file:                    $R1"
[[ "$single_end" == false ]] && echo "Input R2 FASTQ file:                      $R2"
echo "Output dir:                               $outdir"
echo "Minimum overlap between primer and read:  $overlap"
echo "Remove untrimmed reads from main output:  $discard_untrimmed"
echo "Save untrimmed reads to separate files:   $save_untrimmed"
echo "Pair-filter option:                       $pair_filter"
echo "Is the input single-end?                  $single_end"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$R1"
[[ "$single_end" == false ]] && ls -lh "$R2"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               DEFINE PRIMERS
# ==============================================================================
if [[ -z "$primer_file" ]]; then
    log_time "Using the forward and reverse primers provided as arguments to the script..."
    [[ -z "$primer_f" ]] && die "No forward primer (-f) provided"
    [[ -z "$primer_r" ]] && die "No reverse primer (-r) provided"

    primer_f_rc=$(echo "$primer_f" | tr ATCGYRKMBDHV TAGCRYMKVHDB | rev)
    primer_r_rc=$(echo "$primer_r" | tr ATCGYRKMBDHV TAGCRYMKVHDB | rev)

    if [[ "$single_end" == false ]]; then
        primer_opt="-a $primer_f...$primer_r_rc -A $primer_r...$primer_f_rc"
    else
        primer_opt="-a $primer_f...$primer_r_rc"
    fi

    # Report
    log_time "Primer sequences:" 
    echo "Forward primer (-f):              $primer_f"
    echo "Reverse primer (-r):              $primer_r"
    echo "Forward primer - rev. comp.:      $primer_f_rc"
    echo "Reverse primer - rev. comp.:      $primer_r_rc"
    echo "Primer option:                    $primer_opt"
else
    log_time "Using primer file $primer_file to read primers..."
    [[ ! -f "$primer_file" ]] && die "Primer file $primer_file not found"
    i=0

    while read -r primer_f primer_r; do
        i=$((i+1))

        primer_f_rc=$(echo "$primer_f" | tr ATCGYRKMBDHV TAGCRYMKVHDB | rev)
        primer_r_rc=$(echo "$primer_r" | tr ATCGYRKMBDHV TAGCRYMKVHDB | rev)

        if [[ "$single_end" == false ]]; then
            primer_opt_one="-a $primer_f...$primer_r_rc -A $primer_r...$primer_f_rc"
        else
            primer_opt_one="-a $primer_f...$primer_r_rc"
        fi
        # Remove leading whitespace:
        primer_opt_one=$(echo "$primer_opt_one" | sed -E 's/^ +//')
        primer_opt+=" $primer_opt_one"

        # Report
        log_time "PRIMER PAIR NUMBER $i" 
        echo "Forward primer (-f):              $primer_f"
        echo "Reverse primer (-r):              $primer_r"
        echo "Forward primer - rev. comp.:      $primer_f_rc"
        echo "Reverse primer - rev. comp.:      $primer_r_rc"
        echo "Primer option:                    $primer_opt_one"

    done <"$primer_file"

    log_time "Full primer option:                    $primer_opt"
fi

# ==============================================================================
#                               RUN
# ==============================================================================
# Run Cutadapt
log_time "Running $TOOL_NAME..."
if [[ "$single_end" == false ]]; then
    # Paired-end
    runstats $TOOL_BINARY \
            $primer_opt \
            --output "$outdir"/"$R1_filename" \
            --paired-output "$outdir"/"$R2_filename" \
            --pair-filter="$pair_filter" \
            --overlap "$overlap" \
            $untrimmed_opt \
            --cores "$threads" \
            $more_opts \
            "$R1" "$R2" \
            2>&1 | tee "$LOG_DIR"/"$sample_id"_log.txt
else
    # Single-end
    runstats $TOOL_BINARY \
            $primer_opt \
            --output "$outdir"/"$R1_filename" \
            --overlap "$overlap" \
            $untrimmed_opt \
            --cores "$threads" \
            $more_opts \
            "$R1" \
            2>&1 | tee "$LOG_DIR"/"$sample_id"_log.txt
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/"$sample_id"*
final_reporting "$LOG_DIR"
