#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=8G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=fcs-gx-download
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Download the NCBI FCS-GX database (~470 GB) for foreign contamination screening"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=wget
TOOL_NAME="wget (NCBI FCS-GX database download)"
TOOL_DOCS="https://github.com/ncbi/fcs/wiki/FCS-GX"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generic
# NOTE: 'none' - this only needs wget/curl/md5sum, which are always available
env_type=none
container_url=
conda_path=
container_dir="$HOME/containers"
container_path=

# Constants - tool parameters
BASE_URL=https://ncbi-fcs-gx.s3.amazonaws.com/gxdb

# Defaults - tool parameters
db_version=latest           # Which DB build to get ('latest', or e.g. '2023-01-24')
parallel=4                  # Number of files to download simultaneously
verify=true                 # Check each file's MD5 against the manifest

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

The database is about 470 GB across 8 files, so put it on scratch, not on
project storage. FCS-GX itself needs a host with >=512 GB RAM to use it; on
Pitzer that is handled automatically, because the largemem nodes are members
of the default 'batch' partition.

This script is resumable: files that already exist locally with the correct
size (and MD5, unless --no_verify is given) are skipped, so a job that hits
its time limit can simply be resubmitted.

USAGE / EXAMPLE COMMANDS:
  - Basic usage:
      sbatch $0 -o /fs/scratch/PAS0471/\$USER/fcs-gx-db
  - Download a specific database build rather than the current one:
      sbatch $0 -o /fs/scratch/PAS0471/\$USER/fcs-gx-db --db_version 2023-01-24

REQUIRED OPTIONS:
  -o/--outdir         <dir>   Output dir for the database (will be created if needed)

OTHER KEY OPTIONS:
  --db_version        <str>   Database build to download                        [default: $db_version]
  --parallel          <int>   Number of files to download simultaneously        [default: $parallel]
  --no_verify                 Skip the MD5 check (faster, but a corrupt         [default: verify]
                              database fails in confusing ways later)

OUTPUT:
  Alongside the database files, '<outdir>/logs' will contain:
    command.txt     - The command that was run, plus this script's Git commit
    versions.txt    - Versions of this script and of $TOOL_NAME
    shell_env.txt   - The shell environment (credential-like values redacted)
    slurm-*.out     - A copy of the Slurm log (when run as a Slurm job)

UTILITY OPTIONS:
  --env_type          <str>   Software environment: 'conda', 'container'        [default: $env_type]
                              (Singularity/Apptainer), or 'none' (tool must
                              already be available in your PATH)
  --container_url     <str>   URL/URI to download a container from              [default: ${container_url:-none}]
  --container_dir     <str>   Dir to download a container to                    [default: $container_dir]
  --container_path    <file>  Local container image file ('.sif') to use        [default: ${container_path:-none}]
  --conda_path        <dir>   Full path to a Conda environment to use           [default: ${conda_path:-none}]
  -h/--help                   Print this help message
  -v/--version                Print script and $TOOL_NAME versions

TOOL DOCUMENTATION: $TOOL_DOCS
"
}

# Function to source the script with Bash functions
source_function_script() {
    local is_slurm=${1:-false}

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
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -s "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -s "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            tmp_script=$(mktemp "$function_script_name".XXXXXX)
            if ! wget -q "$FUNCTION_SCRIPT_URL" -O "$tmp_script"; then
                rm -f "$tmp_script"
                echo "ERROR: Failed to download $FUNCTION_SCRIPT_URL" >&2
                exit 1
            fi
            mv -f "$tmp_script" "$function_script_name"
        fi
        source "$function_script_name"
    fi

    # Make sure the functions were really loaded
    if ! declare -F log_time check_val >/dev/null; then
        echo "ERROR: Sourced $function_script_name but its functions are missing" >&2
        echo "       (an outdated copy may be cached - try deleting it)" >&2
        exit 1
    fi
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "${SLURM_JOB_ID:-}" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script "$IS_SLURM"

# Report clearly if this script exits with a non-zero status
trap report_on_exit EXIT

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false
outdir=

# Parse command-line options
all_opts="$*"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --db_version )      check_val "$1" "${2:-}"; shift; db_version=$1 ;;
        --parallel )        check_val "$1" "${2:-}"; shift; parallel=$1 ;;
        --no_verify )       verify=false ;;
        --env_type )        check_val "$1" "${2:-}"; shift; env_type=$1 ;;
        --conda_path )      check_val "$1" "${2:-}"; shift; conda_path=$1 ;;
        --container_dir )   check_val "$1" "${2:-}"; shift; container_dir=$1 ;;
        --container_url )   check_val "$1" "${2:-}"; shift; container_url=$1 ;;
        --container_path )  check_val "$1" "${2:-}"; shift; container_path=$1 ;;
        -h | --help )       script_help; exit 0 ;;
        -v | --version)     version_only=true ;;
        * )                 die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Print version info and exit, if requested
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ ! "$parallel" =~ ^[0-9]+$ || "$parallel" -lt 1 ]] &&
    die "--parallel should be a positive integer but is '$parallel'" "$all_opts"

# Define outputs based on script parameters
LOG_DIR=$(realpath -m "$outdir")/logs
mkdir -p "$LOG_DIR"
MANIFEST="$outdir"/all.manifest
DB_URL="$BASE_URL/$db_version"

# Record how this script was called
log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Output (database) dir:                    $outdir"
echo "Database version:                         $db_version"
echo "Database URL:                             $DB_URL"
echo "Parallel downloads:                       $parallel"
echo "Verify MD5 checksums:                     $verify"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
load_env

# --- Get the manifest, which lists the files, their sizes and their MD5 sums ---
log_time "Downloading the database manifest from $DB_URL/all.manifest..."
wget -q -O "$MANIFEST" "$DB_URL"/all.manifest ||
    die "Failed to download the manifest from $DB_URL/all.manifest"

# Turn the manifest JSON into a plain 'name<TAB>size<TAB>md5' table
FILE_TABLE="$LOG_DIR"/manifest_files.tsv
python3 -c "
import json, sys
with open('$MANIFEST') as fh:
    mft = json.load(fh)
for f in mft['fileDetails']:
    print(f\"{f['fileName']}\t{f['fileSize']}\t{f['hashValue']}\")
" > "$FILE_TABLE" || die "Failed to parse the manifest $MANIFEST"

n_files=$(wc -l < "$FILE_TABLE")
total_gb=$(awk -F'\t' '{ s += $2 } END { printf "%.1f", s/1024/1024/1024 }' "$FILE_TABLE")
log_time "The manifest lists $n_files files, $total_gb GB in total:"
awk -F'\t' '{ printf "  %-28s %10.2f GB\n", $1, $2/1024/1024/1024 }' "$FILE_TABLE"

# --- Work out which files still need downloading ---
# A file is considered done if it exists at the expected size (the MD5 check
# comes later, once everything is present)
TODO_LIST="$LOG_DIR"/to_download.txt
: > "$TODO_LIST"
while IFS=$'\t' read -r fname fsize _fmd5; do
    local_file="$outdir/$fname"
    if [[ -f "$local_file" ]] && [[ "$(stat -c %s "$local_file")" == "$fsize" ]]; then
        echo "  Already present, skipping: $fname"
    else
        echo "$fname" >> "$TODO_LIST"
    fi
done < "$FILE_TABLE"

n_todo=$(wc -l < "$TODO_LIST")
if [[ "$n_todo" -eq 0 ]]; then
    log_time "All $n_files files are already present at the expected size - nothing to download"
else
    log_time "Downloading $n_todo of $n_files files, $parallel at a time..."
    # '--continue' resumes a partial file from an interrupted run
    if ! xargs -a "$TODO_LIST" -I{} -P "$parallel" \
            wget -q --continue -O "$outdir"/{} "$DB_URL"/{}; then
        die "One or more files failed to download - rerun this script to resume"
    fi
    log_time "Finished downloading"
fi

# --- Verify ---
log_time "Checking that every file is present at its expected size..."
while IFS=$'\t' read -r fname fsize _fmd5; do
    local_file="$outdir/$fname"
    [[ ! -f "$local_file" ]] && die "File $fname is missing after download"
    actual=$(stat -c %s "$local_file")
    [[ "$actual" != "$fsize" ]] &&
        die "File $fname has size $actual but the manifest says $fsize - delete it and rerun"
done < "$FILE_TABLE"
echo "  All $n_files files present at the expected size"

if [[ "$verify" == true ]]; then
    log_time "Verifying MD5 checksums (this reads all $total_gb GB, so it takes a while)..."
    while IFS=$'\t' read -r fname _fsize fmd5; do
        actual_md5=$(md5sum "$outdir/$fname" | awk '{ print $1 }')
        if [[ "$actual_md5" == "$fmd5" ]]; then
            printf "  OK    %-28s %s\n" "$fname" "$actual_md5"
        else
            die "MD5 mismatch for $fname: got $actual_md5, expected $fmd5 - delete it and rerun"
        fi
    done < "$FILE_TABLE"
    log_time "All checksums matched"
else
    log_time "NOTE: skipping the MD5 check because --no_verify was given"
fi

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
log_time "Listing files in the output dir:"
ls -lhd "$(realpath "$outdir")"/* 2>/dev/null ||
    log_time "WARNING: No files found in the output dir $outdir"
log_time "Point AssemblyQC at this dir with 'ncbi_fcs_gx_db_path' in config/asmqc-params.yml"
final_reporting
