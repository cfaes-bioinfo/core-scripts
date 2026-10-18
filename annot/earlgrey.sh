#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=7-00:00:00
#SBATCH --cpus-per-task=40
#SBATCH --mem=175G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=earlgrey
#SBATCH --output=slurm-%x-%j.out

# Strict Bash settings
set -euo pipefail

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Annotate transposable elements and soft-mask a genome with Earl Grey"
SCRIPT_VERSION="2026-10-18"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=earlGrey
TOOL_NAME="Earl Grey"
TOOL_DOCS=https://github.com/TobyBaril/EarlGrey
VERSION_COMMAND="earlGrey -h | grep -m1 version"

# Defaults - generic
env_type=container
container_url=oras://community.wave.seqera.io/library/earlgrey:7.3.1--4247430cb87f44cc
container_dir="$HOME/containers"
container_path=
conda_path=

# Constants - tool parameters
#  Earl Grey wraps RepeatModeler2 (de novo library) + TEstrainer (consensus
#  curation) + RepeatMasker (annotation) + defragmentation. RepeatModeler2 is
#  well-behaved at ~3 GB/thread, but TEstrainer is NOT (see the OOM note
#  below) - --mem is set to 175 GB, just under the ~178-182 GB a Pitzer
#  'cpu'/'cpu-exp' node actually has, since jobs here get the whole node
#  exclusively regardless of what's requested (see the --cpus-per-task note
#  below), so this headroom is free.
#
#  RUNTIME: the authors quote 4-5 days for a ~400 Mb genome, so a larger
#  assembly may well exceed the 7-day wall time - which is a hard ceiling on
#  Pitzer without access to the 14-day 'longcpu' partition.
#  Earl Grey skips stages whose output already exists, so if the job is killed
#  by the time limit, RESUBMIT THE SAME COMMAND with the same --outdir and it
#  will pick up where it stopped (TEstrainer resumes mid-stage too).
#
#  OOM: job 51752020 (2026-08-25) was OOM-killed at 44 threads partway into
#  TEstrainer's 9th of 10 default BEAT (Blast-Extend-Align-Trim) curation
#  rounds, having exhausted a 160 GB allocation - rounds 1-8 completed fine at
#  the same thread count (run_0..run_9 dirs on disk confirm this), so this
#  reads as memory footprint creeping up round over round (RECON found 2619
#  de novo families here, many satellite/tandem-repeat - a repeat-rich genome
#  - and each round's curated consensi + flanks likely grow), not one
#  anomalous batch. TEstrainer ships its own "cap threads to fit free RAM"
#  safety net, but it is a no-op under Slurm+Apptainer: it reads
#  'free -m', which reports the HOST's total physical memory, not the Slurm
#  cgroup limit, and its hardcoded budget (800 MB/thread) is far too low
#  regardless. --cpus-per-task is similarly unreliable for controlling this:
#  OSC silently raises $SLURM_CPUS_PER_TASK to match the full node it lands
#  on (confirmed: requested 40, got 44), so requesting fewer CPUs would not
#  have reduced concurrency either. This script therefore derives its own,
#  more conservative thread count for the earlGrey call from real allocated
#  memory ($SLURM_MEM_PER_NODE, which Slurm does honor) - see EG_THREADS
#  below the option parsing.

# Defaults - tool parameters
species=
rm_search=actinopterygii   # RepeatMasker/famdb search term ('-r'); 'eukarya' is the broader alternative
softmask=yes               # Write a soft-masked genome at the end ('-d')
dfam_db=                   # Required: dir with the Dfam 'root' + 'curated.consensus' partitions
mem_per_thread_gb=10       # Conservative TEstrainer budget for the OOM fix above; lower it if this still OOMs, raise it to speed TEstrainer up if a run finishes with a lot of unused memory

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

Earl Grey runs the standard RepeatModeler2 -> RepeatMasker workflow but adds
automated consensus curation (TEstrainer: iterative BLAST-extend-extract) and
annotation defragmentation. Against bare RepeatModeler2 it classifies TEs about
equally well but produces markedly less fragmented annotations, which matters
when the repeat GFF is used downstream to filter TE-derived gene models.

CONTAINER CAVEAT: this container is missing a surprising number of basic Unix
utilities (confirmed absent: find, gzip, gunzip, zcat, tar, bc, xargs, diff,
cmp, column, rev) and ships with NO Dfam data at all (~85 MB minimum needed,
not bundled - see --dfam_db below). All of the missing-binary failures are
silent: earlGrey calls most of them with '2>/dev/null' internally, which
swallows bash's "command not found" message, so the job dies at exit 127 with
no diagnostic text - and 'bc' is called on every stage transition, so this
bites immediately, not deep into a run. This script works around all of it: it
bind-mounts working copies of the missing utilities from the host, and
bind-mounts --dfam_db onto the Dfam data path famdb/RepeatMasker expect
(auto-detected inside the container, so it survives a famdb package version
bump). It also checks up front that earlGrey, RepeatMasker, RepeatModeler and
famdb.py are all callable, and that famdb.py can actually read the Dfam data,
before committing to a multi-day run.

A second packaging bug in the same container: RepeatMasker's and RepeatModeler's
'util/*.pl' scripts are symlinked into /opt/conda/bin but locate their own Perl
modules via 'use lib \$FindBin::Bin' - \$Bin (the symlink's dir), not \$RealBin
(the dir it points into) - so @INC never includes the share dir holding the
.pm files. Earl Grey calls one of these, rmOutToGFF3.pl, in its 'Generating GFF
Files' stage and ignores its exit status, so a failure there yields a ZERO-BYTE
GFF and surfaces only ~15 lines later as 'ERROR: strict merge also failed'.
This script sets PERL5LIB inside the container to the real module dirs
(auto-detected) and compiles rmOutToGFF3.pl as a pre-flight check.

Separately, 'apptainer exec' passes the host environment through by default,
so an OSC R module's R_LIBS_USER/R_HOME leaked into the container and made its
R try to load this user's HOST-compiled R packages ('ape', 'tidyverse') -
crashing with "undefined symbol" deep in the final repeat-merging stage, after
days of otherwise-successful runtime. This script unsets those variables
before running $TOOL_NAME. PERL5LIB is set via APPTAINERENV_PERL5LIB for the
same reason: it overrides rather than inherits whatever the host has.

DFAM DATABASE: --dfam_db must contain the 'root' and 'curated.consensus'
partitions (dfam40.0.h5, dfam40.curated.consensus.0.h5; ~85 MB compressed,
~576 MB decompressed) from https://www.dfam.org/releases/current/families/FamDB/.
This is all RepeatMasker's default search engine (rmblast, not HMM-based) uses;
the curated HMM and uncurated partitions run 2-165 GB and are not needed here.
Fetch them with (piping the '1,2' partition selection into its interactive
prompt; find must still be bind-mounted, download_dfam.py uses it too):
    echo '1,2' | apptainer exec --bind /usr/bin/find:/usr/local/bin/find \
        <sif> download_dfam.py -o <dfam_db>

INPUT-DIR SIDE EFFECT: Earl Grey writes '<genome>.prep', '<genome>.dict' and
'<genome>.bak.gz' NEXT TO the input genome. To keep the assembly directory
clean, this script symlinks the assembly into the output dir and runs on that
symlink, so those files land in the output dir instead.

RESUMING: rerunning with the same --outdir skips completed stages. The
'output dir already contains files' warning is expected in that case.

USAGE / EXAMPLE COMMANDS:
  - Basic usage:
      sbatch $0 -i data/assembly.fasta \\
          -o results/earlgrey --species Oneirodes_acanthias
  - Use the broader Dfam search term and skip the soft-masked genome:
      sbatch $0 -i ... -o ... --species ... --rm_search eukarya --softmask no
  - Pass extra options to $TOOL_NAME (note the quoting):
      sbatch $0 -i ... -o ... --species ... --more_opts \"-e yes -c yes\"

REQUIRED OPTIONS:
  -i/--infile         <file>  Input assembly nucleotide FASTA
  -o/--outdir         <dir>   Output dir (will be created if needed)
  --species           <str>   Species name, no spaces (e.g. 'Oneirodes_acanthias').
                              Earl Grey uses it to name its output dirs and files

OTHER KEY OPTIONS:
  --rm_search         <str>   RepeatMasker/famdb search term ('-r')             [default: $rm_search]
                              Use 'eukarya' for the full curated Dfam set
  --softmask          <yes|no> Write a soft-masked genome ('-d')                [default: $softmask]
  --dfam_db           <dir>   Dir with the 'root' + 'curated.consensus' Dfam    [required with --env_type container]
                              partitions (see DFAM DATABASE above)
  --mem_per_thread_gb <int>   GB of allocated memory to reserve per thread when  [default: $mem_per_thread_gb]
                              capping TEstrainer's concurrency (see OOM note
                              in this script) - lower if a run still OOMs
  --more_opts         <str>   Quoted string with one or more additional options
                              for $TOOL_NAME

OUTPUT:
  Everything lands in <outdir>/<species>_EarlGrey/, with the key files copied
  into <outdir>/<species>_EarlGrey/<species>_summaryFiles/:
    <species>.softmasked.fasta            - Soft-masked assembly (input for GALBA)
    <species>.filteredRepeats.gff / .bed  - Final TE annotation
    <species>_combined_library.fasta      - Curated TE consensus library
    <species>.highLevelCount.txt          - TE counts per high-level class
    <species>.summaryPie.pdf              - TE composition pie chart
    <species>_divergence_summary_table.tsv + RepeatLandscape PDF - Kimura landscape
  Alongside those, '<outdir>/logs' will contain:
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
            # Download to a temp file, then move into place, so that concurrent
            # jobs can never source a half-written file
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
infile=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
all_opts_q=$(printf '%q ' "$@")   # Shell-quoted, so it can be re-run exactly
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i | --infile )     check_val "$1" "${2:-}"; shift; infile=$1 ;;
        -o | --outdir )     check_val "$1" "${2:-}"; shift; outdir=$1 ;;
        --species )         check_val "$1" "${2:-}"; shift; species=$1 ;;
        --rm_search )       check_val "$1" "${2:-}"; shift; rm_search=$1 ;;
        --softmask )        check_val "$1" "${2:-}"; shift; softmask=$1 ;;
        --dfam_db )         check_val "$1" "${2:-}"; shift; dfam_db=$1 ;;
        --mem_per_thread_gb ) check_val "$1" "${2:-}"; shift; mem_per_thread_gb=$1 ;;
        --more_opts )       check_val "$1" "${2:-}" lax; shift; more_opts=$1 ;;
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
# Check software env
[[ "$env_type" == "conda" && -z "$conda_path" ]] &&
    die "No Conda env: set 'conda_path' in this script or use --conda_path" "$all_opts"
[[ "$env_type" == "container" && -z "$container_url" && -z "$container_path" ]] &&
    die "No container: set 'container_url' in this script or use --container_url/--container_path" "$all_opts"

# Print version info and exit, if requested (this needs the software env loaded)
if [[ "$version_only" == true ]]; then
    load_env
    print_version "$VERSION_COMMAND"
    exit 0
fi

# Check options provided to the script
[[ -z "$infile" ]] && die "No input file specified, do so with -i/--infile" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -z "$species" ]] && die "No species name specified, do so with --species" "$all_opts"
[[ ! -f "$infile" ]] && die "Input file $infile does not exist"
[[ "$species" == *" "* ]] &&
    die "--species should not contain spaces but is '$species'" "$all_opts"
[[ ! "$softmask" =~ ^(yes|no)$ ]] &&
    die "--softmask should be 'yes' or 'no' but is '$softmask'" "$all_opts"
if [[ "$env_type" == "container" ]]; then
    [[ -z "$dfam_db" ]] &&
        die "No Dfam database dir specified, do so with --dfam_db - see the DFAM DATABASE note in '$0 --help'" "$all_opts"
    [[ ! -d "$dfam_db" ]] &&
        die "Dfam database dir $dfam_db does not exist - see the DFAM DATABASE note in '$0 --help'" "$all_opts"
    [[ ! -f "$dfam_db/dfam40.0.h5" || ! -f "$dfam_db/dfam40.curated.consensus.0.h5" ]] &&
        die "Dfam database dir $dfam_db is missing dfam40.0.h5 or dfam40.curated.consensus.0.h5 - see the DFAM DATABASE note in '$0 --help'"
fi

# Warn if the output dir already holds results from a previous run
# NOTE: for this script that is also the normal state when resuming - see the help
check_outdir "$outdir"

# Define outputs based on script parameters
# NOTE: LOG_DIR is made absolute so that log paths keep resolving if the
#       script (or the tool) changes the working dir later on
OUTDIR_ABS=$(realpath -m "$outdir")
LOG_DIR="$OUTDIR_ABS"/logs
mkdir -p "$LOG_DIR"
EG_DIR="$OUTDIR_ABS/${species}_EarlGrey"
SUMMARY_DIR="$EG_DIR/${species}_summaryFiles"
MASKED_FA="$SUMMARY_DIR/$species.softmasked.fasta"
STRAINER_DIR="$EG_DIR/${species}_strainer"
STRAINED_LIB="$STRAINER_DIR/${species}-families.fa.strained"
CURATED_LIB="$EG_DIR/${species}_Curated_Library/${species}_combined_library.fasta"

# Earl Grey writes '<genome>.prep', '<genome>.dict' and '<genome>.bak.gz' next to
# the genome it is given. Run it on a symlink inside the output dir so that those
# files land there rather than in the assembly dir. Earl Grey's prepGenome()
# resolves symlinks with 'realpath -s', i.e. it keeps the symlink's own path.
GENOME_LINK="$OUTDIR_ABS/$(basename "$infile")"
ln -sf "$(realpath "$infile")" "$GENOME_LINK"

# Record how this script was called (and, under Slurm, which job ran it)
log_provenance "$LOG_DIR"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:        $all_opts"
echo "Working directory:                        $PWD"
echo
echo "Input assembly:                           $infile"
echo "Output dir:                               $outdir"
echo "Genome symlink used as input:             $GENOME_LINK"
echo "Species name:                             $species"
echo "RepeatMasker search term:                 $rm_search"
echo "Create a soft-masked genome:              $softmask"
echo "Dfam database dir:                        $dfam_db"
echo "Temp dir (\$TMPDIR):                       ${TMPDIR:-<unset>}"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:        $more_opts"
log_time "Listing the input file(s):"
ls -lh "$infile"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# Thread count actually passed to earlGrey ('threads' is read-only and reflects
# $SLURM_CPUS_PER_TASK, which - per the OOM note near the top of this script -
# does not reliably track what was requested, so it is not safe to use as-is
# for TEstrainer's concurrency). Cap it using memory Slurm actually enforces.
EG_THREADS=$threads
if [[ -n "${SLURM_MEM_PER_NODE:-}" ]]; then
    mem_gb=$(( SLURM_MEM_PER_NODE / 1024 ))
    safe_threads=$(( mem_gb / mem_per_thread_gb ))
    if (( safe_threads > 0 && safe_threads < EG_THREADS )); then
        log_time "Capping threads passed to $TOOL_NAME from $EG_THREADS to $safe_threads (${mem_gb} GB allocated / $mem_per_thread_gb GB per thread - see the OOM note in this script)"
        EG_THREADS=$safe_threads
    fi
fi
echo "Threads passed to $TOOL_NAME:                 $EG_THREADS"

# ==============================================================================
#                               RUN
# ==============================================================================
# Load the software environment
load_env

# 'apptainer exec' (unlike Docker) passes the host environment straight through
# to the container by default. OSC's R module sets R_LIBS_USER/R_HOME on the
# host, so the container's R was picking up this user's personal R library
# (~/R/rhel9/4.5.2), which is compiled against the HOST's R/glibc toolchain.
# Earl Grey's merge/backSwap R steps (needing 'ape', 'tidyverse') then crashed
# with "undefined symbol" trying to dlopen those host .so files against the
# container's own R runtime - job 51831383 (2026-08-25) died this way after
# 4.5 days, well past TEstrainer, at the final repeat-merging stage. Unset
# them so the container's own R library is used.
unset R_LIBS_USER R_LIBS R_HOME

# This container is missing a surprising number of basic Unix utilities -
# confirmed absent: find, gzip, gunzip, zcat, tar, bc, xargs, diff, cmp, column -
# and ships with no Dfam data at all. All of the missing-binary failures are
# silent: earlGrey calls most of them with '2>/dev/null' internally (e.g.
# resolveFamdbPath()'s 'find ... 2>/dev/null'), which swallows bash's "command
# not found" message, so the job dies at exit 127 with no diagnostic text - and
# 'bc' is called on every single stage transition via runningTea()'s timer, so
# this is not an edge case. Bind-mount working copies of all of them from the
# host, plus the Dfam database from --dfam_db (the famdb package's share dir is
# discovered at runtime so this survives a version bump of that conda package).
if [[ "$env_type" == "container" ]]; then
    missing_utils="find gzip gunzip zcat tar bc xargs diff cmp column rev"
    util_binds=
    for util in $missing_utils; do
        host_path=$(command -v "$util") ||
            die "No '$util' binary found on the host to bind into the container"
        util_binds="${util_binds:+$util_binds,}$host_path:/usr/local/bin/$util"
    done
    famdb_dir=$(apptainer exec "$container_path" bash -c \
        'basename "$(ls -d /opt/conda/share/famdb-*/ 2>/dev/null | head -n1)"')
    [[ -z "$famdb_dir" ]] &&
        die "Could not locate the famdb package's share dir inside the container - has it been rebuilt?"
    log_time "Bind-mounting host utilities ($missing_utils) and the Dfam database ($famdb_dir) into the container"
    export APPTAINER_BIND="${APPTAINER_BIND:+$APPTAINER_BIND,}$util_binds,$(realpath "$dfam_db"):/opt/conda/share/$famdb_dir/Libraries/famdb"

    # RepeatMasker's and RepeatModeler's 'util/*.pl' helper scripts are symlinked
    # into /opt/conda/bin, and they find their own Perl modules with
    #     use FindBin; use lib $FindBin::Bin; use lib "$FindBin::Bin/../";
    # i.e. $Bin (the symlink's dir) rather than $RealBin (the dir the symlink
    # points into). So @INC becomes '/opt/conda/bin' + '/opt/conda/', neither of
    # which holds any .pm file - 12 of these scripts are broken this way in this
    # build. Earl Grey's "Generating GFF Files" stage calls one of them,
    # rmOutToGFF3.pl, which dies with "Can't locate CrossmatchSearchEngine.pm";
    # earlGrey does not check its exit status, so the stage silently produces a
    # ZERO-BYTE '.out.gff3'. RepeatCraft then merges an empty GFF, and the whole
    # defragmentation stage collapses ~15 lines later with a much less
    # informative "ERROR: strict merge also failed" (job 51855200, 2026-08-27,
    # after 2.5 days - everything upstream of it had run correctly).
    # Point PERL5LIB at the real module dirs. Note APPTAINERENV_ rather than a
    # plain export: that way this also OVERRIDES any PERL5LIB leaking in from
    # the host, which is the same trap R_LIBS_USER set for us above.
    perl_lib_dirs=$(apptainer exec "$container_path" bash -c \
        'ls -d /opt/conda/share/RepeatMasker*/ /opt/conda/share/RepeatModeler*/ 2>/dev/null')
    [[ -z "$perl_lib_dirs" ]] &&
        die "Could not locate the RepeatMasker/RepeatModeler Perl module dirs inside the container - has it been rebuilt?"
    APPTAINERENV_PERL5LIB=$(echo "$perl_lib_dirs" | sed 's|/$||' | paste -sd: -)
    export APPTAINERENV_PERL5LIB
    log_time "Setting PERL5LIB inside the container to $APPTAINERENV_PERL5LIB"
fi

# Pre-flight: fail now, not several days in, if the container is missing a
# component, or if the bind-mounted Dfam database is not actually readable.
log_time "Checking that all Earl Grey components are callable..."
if ! ${CONTAINER_PREFIX:-} bash -c 'command -v earlGrey RepeatMasker RepeatModeler famdb.py'; then
    die "One or more Earl Grey components are missing from the software environment"
fi
if [[ "$env_type" == "container" ]] &&
   ! ${CONTAINER_PREFIX:-} famdb.py -i /opt/conda/share/"$famdb_dir"/Libraries/famdb info > /dev/null; then
    die "famdb.py could not read the Dfam database bind-mounted from $dfam_db"
fi
# rmOutToGFF3.pl must be able to load its Perl modules (see the PERL5LIB note
# above) - compiling it is instant and catches the breakage now rather than
# after days of RepeatModeler/TEstrainer/RepeatMasker runtime.
if [[ "$env_type" == "container" ]] &&
   ! ${CONTAINER_PREFIX:-} bash -c 'perl -c "$(command -v rmOutToGFF3.pl)"' > /dev/null 2>&1; then
    die "rmOutToGFF3.pl cannot load its Perl modules with PERL5LIB=$APPTAINERENV_PERL5LIB
       Earl Grey's 'Generating GFF Files' stage would silently write an empty GFF
       and the defragmentation stage would then fail with 'strict merge also failed'."
fi

# Pre-flight: refuse to resume on top of an EMPTY strained library.
# TEstrainer_for_earlGrey.sh has no 'set -e' and ends with:
#     if [ -f .../classify/<lib>.nonsatellite.classified ]; then cp ... .strained
#     else touch <lib>.strained; fi
# so ANY failure in its post-BEAT steps (the 'simple_repeat_filter_trim.R' step
# in particular - see the R_LIBS note above, which is exactly how this bit us)
# leaves a ZERO-BYTE '.strained' and exits 0. Earl Grey then masks the genome
# with the stock RepeatMasker library and NO de novo families, silently.
# Worse, on the next resubmission earlGrey's stage-4 test is
#     if [ ! -s .strained ]; then if [ -f .strained ]; then rm -r .strained TS*
# i.e. a zero-byte '.strained' makes it DELETE the whole TEstrainer working dir
# and redo every BEAT round from scratch (job 51842580 lost 9 rounds this way,
# and re-hit the round-9 OOM that had been fixed by hand in the discarded dir).
# Stop here instead and let a human decide what to keep.
if [[ -e "$STRAINED_LIB" && ! -s "$STRAINED_LIB" ]]; then
    die "$STRAINED_LIB is empty: the previous run's TEstrainer post-processing failed silently.
       Resuming now would make Earl Grey delete $STRAINER_DIR/TS_* and redo every BEAT round.
       Inspect that dir first, then delete ONLY the empty '.strained' file to resume mid-BEAT."
fi

# Pre-flight: refuse to resume onto a RepeatMasker run made with a different
# (or de-novo-free) library. Earl Grey's stage-5 test is just
#     if [ ! -f <RM_against_custom_lib>/*.tbl ]
# so ANY leftover '.tbl' makes it skip the final masking entirely and defragment
# the OLD annotation - even if TEstrainer has just rebuilt the library from
# scratch. Clear those dirs when the library is being redone.
RM_CUSTOM_TBL=$(ls "$EG_DIR/${species}_RepeatMasker_Against_Custom_Library"/*.tbl 2>/dev/null | head -n1 || true)
if [[ -n "$RM_CUSTOM_TBL" && -s "$CURATED_LIB" ]] &&
   ! grep -q "^>rnd-" "$CURATED_LIB"; then
    die "$CURATED_LIB holds no de novo (rnd-*) families, but $RM_CUSTOM_TBL exists.
       Earl Grey would skip the final masking and reuse that stale annotation.
       Move ${species}_RepeatMasker_Against_Custom_Library, ${species}_Curated_Library and
       ${species}_mergedRepeats aside before resuming."
fi

# Run the tool
# '-q yes' suppresses TEstrainer's parallel progress bar, which is pure noise in
# a Slurm log; '-t' is the thread count Earl Grey passes on to its components
log_time "Running $TOOL_NAME (expect multiple days - see the RUNTIME note in this script)..."
eval runstats "$TOOL_BINARY" \
    -g "$GENOME_LINK" \
    -s "$species" \
    -o "$OUTDIR_ABS" \
    -t "$EG_THREADS" \
    -r "$rm_search" \
    -d "$softmask" \
    -q yes \
    $more_opts

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
# Post-run check: the curated library must actually contain de novo families.
# This is the same silent failure the pre-flight check above guards against, but
# caught on the run that CAUSED it rather than on the resubmission - if the
# combined library holds only the stock '--rm_search' RepeatMasker library, every
# downstream number in this log is meaningless (job 51831383 masked the whole
# genome this way and nothing in Earl Grey's output said so).
if [[ -e "$STRAINED_LIB" && ! -s "$STRAINED_LIB" ]]; then
    log_time "ERROR: TEstrainer produced an EMPTY curated library ($STRAINED_LIB)."
    echo "       Its post-BEAT steps failed but it exited 0 (it has no 'set -e' and ends in a bare 'touch')."
    echo "       Check $STRAINER_DIR/TS_*/ and the R steps in this log; do NOT resubmit as-is."
    die "Earl Grey ran to completion against a library with no de novo repeats"
fi
if [[ -s "$CURATED_LIB" ]]; then
    n_denovo=$(grep -c "^>rnd-" "$CURATED_LIB" || true)
    log_time "Curated library: $(grep -c "^>" "$CURATED_LIB") sequences, of which $n_denovo de novo (rnd-*) families"
    (( n_denovo == 0 )) &&
        die "No de novo families in $CURATED_LIB - the genome was masked with the stock $rm_search library only"
fi

# Report the headline numbers, so the run can be judged without opening files.
# For a teleost, expect roughly 30-45% of the assembly to be masked -
# a much lower figure means the de novo library step underperformed.
if [[ -f "$MASKED_FA" ]]; then
    log_time "Soft-masked fraction of $(basename "$MASKED_FA"):"
    awk '!/^>/ { s = $0; tot += length(s); lc += gsub(/[a-z]/, "", s) }
         END { if (tot > 0) printf "  %d of %d bp soft-masked (%.2f%%)\n", lc, tot, 100 * lc / tot }' \
        "$MASKED_FA"
else
    log_time "NOTE: no soft-masked genome at $MASKED_FA (expected when --softmask no)"
fi

if [[ -f "$SUMMARY_DIR/$species.highLevelCount.txt" ]]; then
    log_time "TE counts per high-level class:"
    cat "$SUMMARY_DIR/$species.highLevelCount.txt"
fi

log_time "Listing files in the summary dir:"
ls -lh "$SUMMARY_DIR" 2>/dev/null ||
    log_time "WARNING: No summary dir found at $SUMMARY_DIR"
final_reporting
