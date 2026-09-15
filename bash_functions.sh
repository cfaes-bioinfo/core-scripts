#!/bin/bash

# Constants
OSC_MODULE=miniconda3/24.1.2-py310

# Dummy defaults
[[ -z "${env_type:-}" ]] && env_type=conda
[[ -z "${container_path:-}" ]] && container_path=
[[ -z "${container_url:-}" ]] && container_url=
[[ -z "${container_dir:-}" ]] && container_dir=
[[ -z "${conda_path:-}" ]] && conda_path=
[[ -z "${SCRIPT_NAME:-}" ]] && SCRIPT_NAME=script-name
[[ -z "${SCRIPT_VERSION:-}" ]] && SCRIPT_VERSION=script-version
[[ -z "${SCRIPT_AUTHOR:-}" ]] && SCRIPT_AUTHOR=script-author
[[ -z "${TOOL_NAME:-}" ]] && TOOL_NAME=tool-name
[[ -z "${REPO_URL:-}" ]] && REPO_URL=https://github.com/mcic-osu/mcic-scripts
[[ -z "${VERSION_COMMAND:-}" ]] && VERSION_COMMAND=

# Variables that can/should be loaded in the script calling these functions
# conda_path        - Absolute path to a Conda environment dir
# container_url     - URL/URI to a container
# container_path    - Absolute path to a container .sif file
# TOOL_BINARY       - The command that calls the focal program 
# SCRIPT_NAME       - Name of the shell script
# SCRIPT_VERSION    - Version of the shell script
# SCRIPT_AUTHOR     - Author of the shell script
# REPO_URL          - URL to the GitHub repo

# Load Conda or container env
# NOTE: takes no arguments - reads the env_type/conda_path/container_* globals.
#       Call sites across this repo pass 1-5 vestigial args that are ignored,
#       so do NOT add parameters here without updating all of them.
load_env() {
    if [[ "$env_type" == "conda" ]]; then
        load_conda
    elif [[ "$env_type" == "container" ]]; then
        load_container
    elif [[ "$env_type" == "none" ]]; then
        log_time "NOTE: not using a Conda environment OR a container, software expected to be in PATH"
    else
        die "Execution environment ('--env_type') should be 'conda', 'container', or 'none' but is currently $env_type"
    fi
}

# Load Conda env
load_conda() {
    set +u

    # Load the OSC Conda module
    module load "$OSC_MODULE"

    # Deactivate any active Conda environment
    if [[ -n "$CONDA_SHLVL" ]]; then
        local i
        for i in $(seq "${CONDA_SHLVL}"); do conda deactivate 2>/dev/null; done
    fi

    # Activate the focal environment
    log_time "Loading Conda environment $conda_path"
    conda activate "$conda_path"

    # No container prefix when using a Conda env
    CONTAINER_PREFIX=

    set -u
}

# Set up container
load_container() {
    local dl_container=false url_basename tmp_sif

    # Silence Apptainer's INFO messages (e.g. "gocryptfs not found"), which are
    # just noise. Warnings and fatal errors are still shown - note that
    # '--silent' would hide warnings too, so it is deliberately not used.
    # Run with APPTAINER_QUIET=false to see the INFO messages when debugging.
    export APPTAINER_QUIET=${APPTAINER_QUIET:-true}
    
    # If no path to a container image file was provided,
    # then build the path based on the URL, and check if the file exists
    if [[ -z "$container_path" ]]; then
        url_basename=$(basename "$container_url")
        container_path="$container_dir"/${url_basename/:/_}.sif
        
        if [[ -f "$container_path" ]]; then
            log_time "No container path was provided, but the container image from\n   $container_url\n   was found at $container_path and will be used."
        else
            dl_container=true
        fi
    fi

    # Make sure a user-supplied container image actually exists
    [[ -n "$container_path" && "$dl_container" == false && ! -f "$container_path" ]] &&
        die "Container image file $container_path does not exist"

    # If needed, download the container image
    if [[ "$dl_container" == true ]]; then
        log_time "Downloading container from $container_url to $container_path"
        mkdir -p "$container_dir"
        # Pull to a temp file, then move into place, so that concurrent
        # array jobs can never exec a half-written image
        tmp_sif=$(mktemp "$container_path".XXXXXX)
        if apptainer pull --force "$tmp_sif" "$container_url"; then
            mv -f "$tmp_sif" "$container_path"
        else
            rm -f "$tmp_sif"
            die "Failed to download container from $container_url"
        fi
    fi

    # Set the final 'prefix' to run the container
    CONTAINER_PREFIX="apptainer exec $container_path"
    TOOL_BINARY="$CONTAINER_PREFIX $TOOL_BINARY"
    VERSION_COMMAND="$CONTAINER_PREFIX $VERSION_COMMAND"
    log_time "Using a container with base call: $CONTAINER_PREFIX"
}

# Print the script version only
print_script_version() {
    log_time "Version of this shell script:"
    echo "$SCRIPT_NAME by $SCRIPT_AUTHOR, version $SCRIPT_VERSION ($REPO_URL)"
}

# Print the script AND tool's version
print_version() {
    local version_command=${1-none}
    set +e
    
    print_script_version

    log_time "Version of $TOOL_NAME:"
    if [[ "$version_command" == "none" ]]; then
        $TOOL_BINARY --version
    else
        eval $version_command
    fi
    
    set -e
}

# Record how this script was called, which version of it was used, and -
# under Slurm - which job produced the output
# NOTE: also sets the SLURM_LOG_PATH global, which final_reporting() uses to
#       copy the Slurm log into the log dir. Do not drop that here.
log_provenance() {
    local log_dir=$1
    local repo_version
    repo_version=$(git -C "${script_dir:-.}" describe --always --dirty --tags 2>/dev/null) ||
        repo_version=

    # Locate this job's Slurm log, so it can be found (and copied) later
    # Best-effort: a transient scontrol failure must not kill the job
    if [[ "${IS_SLURM:-false}" == true ]]; then
        SLURM_LOG_PATH=$(scontrol show job "$SLURM_JOB_ID" 2>/dev/null |
                         awk 'match($0, /StdOut=[^[:space:]]+/) {print substr($0, RSTART+7, RLENGTH-7); exit}') ||
            SLURM_LOG_PATH=
    fi

    {
        echo "# Date:         $(date +'%Y-%m-%d %H:%M:%S')"
        echo "# Host:         $(hostname)"
        echo "# Working dir:  $PWD"
        echo "# Script:       ${script_dir:-.}/${SCRIPT_NAME:-unknown}"
        [[ -n "$repo_version" ]] && echo "# Script repo:  $repo_version"
        if [[ "${IS_SLURM:-false}" == true ]]; then
            echo "# Slurm job ID: ${SLURM_JOB_ID:-unknown}"
            echo "# Slurm job:    ${SLURM_JOB_NAME:-unknown}"
            echo "# Slurm log:    ${SLURM_LOG_PATH:-unknown}"
        fi
        echo
        echo "cd $PWD"
        echo "bash ${script_dir:-.}/${SCRIPT_NAME:-unknown} ${all_opts_q:-${all_opts:-}}"
    } > "$log_dir"/command.txt
}

# Print SLURM job resource usage info
# Best-effort: never abort the script, since this runs during final reporting
resource_usage() {
    echo
    report_peak_mem
    check_time_limit
    # NOTE: sacct is deliberately not called here - accounting is not finalized
    #       until the job ends, so in-job it returns a blank MaxRSS/TotalCPU and
    #       reports State=RUNNING. The peak memory above comes from the job's
    #       own cgroup, which is accurate immediately.
    echo "For final accounting figures once the job has ended, run:  seff ${SLURM_JOB_ID:-<jobid>}"
}

# Print SLURM job requested resources
slurm_resources() {
    set +u
    log_time "SLURM job information:"
    echo "Account (project):                        $SLURM_JOB_ACCOUNT"
    echo "Job ID:                                   $SLURM_JOB_ID"
    echo "Job name:                                 $SLURM_JOB_NAME"
    if [[ -n "$SLURM_MEM_PER_NODE" ]]; then
        echo "Memory (GB per node):                     $(( SLURM_MEM_PER_NODE / 1024 ))"
    elif [[ -n "$SLURM_MEM_PER_CPU" ]]; then
        echo "Memory (GB per CPU):                      $(( SLURM_MEM_PER_CPU / 1024 ))"
    else
        echo "Memory:                                   unknown"
    fi
    echo "CPUs (on node):                           $SLURM_CPUS_ON_NODE"
    echo "Time limit (minutes):                     $(( SLURM_TIME_LIMIT / 60 ))"
    echo -e "==========================================================================\n"
    set -u
}

# Set the number of threads/CPUs
set_threads() {
    local is_slurm=$1
    set +u
    
    if [[ "$is_slurm" == true ]]; then
        if [[ -n "$SLURM_CPUS_PER_TASK" ]]; then
            readonly threads="$SLURM_CPUS_PER_TASK"
        elif [[ -n "$SLURM_NTASKS" ]]; then
            readonly threads="$SLURM_NTASKS"
        else 
            log_time "WARNING: This is a Slurm job, but this script can't detect the number of threads/cores: setting to 1"
            readonly threads=1
        fi
    else
        log_time "This is not a Slurm job, setting number of threads to 1"
        readonly threads=1
    fi
    
    export threads
    set -u
}

# Print command ran and its resource usage information for any process
runstats() {
    /usr/bin/time -f \
        "\n# Ran the command: \n%C
        \n# Run stats by /usr/bin/time:
        Time: %E   CPU: %P    Max mem: %M K    Exit status: %x \n" \
        "$@"
}

# Print log messages that include the time
log_time() {
    echo -e "\n[$(date +'%Y-%m-%d %H:%M:%S')] ${1-}";
}

# Exit upon error with a message
die() {
    local error_message=${1:-(no error message provided)}
    local error_args=${2-none}

    log_time "$SCRIPT_NAME: ERROR: $error_message" >&2
    log_time "For help, run this script with the '-h' or '--help' option, e.g:" >&2
    echo "bash $SCRIPT_NAME --help" >&2

    if [[ "$error_args" != "none" ]]; then
        log_time "All options passed to the script:" >&2
        echo "$error_args" >&2
    fi

    print_script_version >&2

    log_time "EXITING..." >&2
    exit 1
}

# Make sure an option that requires a value was given one
# Pass 'lax' as the 3rd arg for options whose value may start with a '-'
check_val() {
    [[ -z "$2" ]] && die "Option $1 requires a value" "$all_opts"
    [[ "${3:-}" != lax && "$2" == -* ]] &&
        die "Option $1 got '$2', which looks like another option" "$all_opts"
    return 0
}

# Warn if the output dir already contains results from a previous run
check_outdir() {
    local outdir=$1 existing
    [[ -d "$outdir" ]] || return 0
    # '|| true': with many entries, 'find' can get SIGPIPE once 'head -1' exits after
    # its first line, which would otherwise abort the whole script under pipefail+errexit
    existing=$(find "$outdir" -mindepth 1 -maxdepth 1 -not -name logs 2>/dev/null | head -1) || true
    [[ -n "$existing" ]] &&
        log_time "WARNING: output dir $outdir already contains files - results may be mixed with a previous run"
    return 0
}

# Warn if the job used most of its Slurm time limit
check_time_limit() {
    local limit_s=${SLURM_TIME_LIMIT:-0} used_s=$SECONDS pct
    [[ "$limit_s" -le 0 ]] && return 0
    pct=$(( 100 * used_s / limit_s ))
    printf "Wall time used: %d:%02d:%02d of %d:%02d:00 limit (%d%%)\n" \
        $((used_s/3600)) $((used_s%3600/60)) $((used_s%60)) \
        $((limit_s/3600)) $((limit_s%3600/60)) "$pct"
    [[ "$pct" -ge 80 ]] &&
        log_time "WARNING: used ${pct}% of the time limit - request more time for larger runs"
    return 0
}

# Report peak memory use, read from the job's own cgroup (cgroup v2)
# Silently does nothing if the cgroup file is unavailable (e.g. cgroup v1)
report_peak_mem() {
    local cgroup peak_file peak_bytes req_mb
    cgroup=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup 2>/dev/null) || return 0
    peak_file="/sys/fs/cgroup${cgroup}/memory.peak"
    [[ -r "$peak_file" ]] || return 0
    peak_bytes=$(cat "$peak_file" 2>/dev/null) || return 0
    [[ "$peak_bytes" =~ ^[0-9]+$ ]] || return 0

    # Memory requested from Slurm, in MB (per-node, else per-CPU x CPUs)
    req_mb=${SLURM_MEM_PER_NODE:-}
    if [[ -z "$req_mb" && -n "${SLURM_MEM_PER_CPU:-}" ]]; then
        req_mb=$(( SLURM_MEM_PER_CPU * ${SLURM_CPUS_ON_NODE:-1} ))
    fi

    awk -v b="$peak_bytes" -v r="${req_mb:-0}" 'BEGIN {
        g = b / 1073741824
        if (r > 0) printf "Peak memory used: %.1f GB of %.1f GB requested (%.0f%%)\n", g, r/1024, 100*g/(r/1024)
        else       printf "Peak memory used: %.1f GB\n", g
    }'
}

# Report clearly if the script exits with a non-zero status (use with 'trap ... EXIT')
report_on_exit() {
    local exit_status=$?
    if [[ "$exit_status" -ne 0 ]]; then
        log_time "ERROR: script ${SCRIPT_NAME:-$0} exited with status $exit_status" >&2
        [[ "$exit_status" -eq 137 ]] &&
            echo "NOTE: status 137 = killed by SIGKILL, usually an out-of-memory kill" >&2
        # Only meaningful under Slurm: outside it, the cgroup is the whole
        # login session rather than this job
        [[ "${IS_SLURM:-false}" == true ]] && report_peak_mem >&2
        check_time_limit >&2
        if [[ "${IS_SLURM:-false}" == true ]]; then
            echo "Slurm job ID: ${SLURM_JOB_ID:-unknown}" >&2
            echo "For full resource usage once the job has ended, run:  seff ${SLURM_JOB_ID:-<jobid>}" >&2
        fi
    fi
}

# Final reporting
# NOTE: takes no arguments - reads the LOG_DIR/env_type/IS_SLURM globals.
#       See the note on load_env() before adding parameters here.
final_reporting() {
    local VERSION_FILE="$LOG_DIR"/versions.txt
    local ENV_FILE="$LOG_DIR"/shell_env.txt
    local CONDA_YML="$LOG_DIR"/conda_env.yml

    # Store the Conda env in a YAML file
    [[ "$env_type" == "conda" ]] && conda env export --no-build > "$CONDA_YML"

    printf "\n======================================================================"
    log_time "Versions used:"
    print_version "$VERSION_COMMAND" | tee "$VERSION_FILE" 
    # Redact credential-like values so they are not written into the results dir
    env | sort |
        sed -E 's/^([A-Za-z_]*(TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|API_KEY|CREDENTIAL|AUTH)[A-Za-z_]*=).*/\1<redacted>/I' \
        > "$ENV_FILE"
    [[ "$IS_SLURM" == true ]] && resource_usage

    # Best-effort copy of the Slurm log; it is still open, so the last few
    # lines (including the 'Successfully completed' line below) will be missing
    if [[ "${IS_SLURM:-false}" == true && -f "${SLURM_LOG_PATH:-}" ]]; then
        cp -f "$SLURM_LOG_PATH" "$LOG_DIR"/
    fi

    log_time "Successfully completed script $SCRIPT_NAME\n"
}
