#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --job-name=entap-config
#SBATCH --output=slurm-entap-config-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
# Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "               CONFIGURE ENTAP (PRIOR TO ANNOTATION)"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 -c <config file> -o <output dir> [...] [ <db-FASTA-1> <db-FASTA-2> ...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  --config_out    <file>  Output EnTAP config file"
    echo "  --db_dir        <dir>   Output dir for EnTAP database files (will be created if needed)" 
    echo "  --taxon         <str>   Taxon name (use underscores, e.g. homo_sapiens)"
    echo "  --contam        <str>   Comma-separated list of contaminant taxa"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  => One or more database protein FASTA files as positional arguments"
    echo "  --config_in     <file>  Input EnTAP config file"
    echo "                          Default: download & use file at https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/annot/entap_config.ini"
    echo "  --more_args     <str>   Quoted string with additional argument(s) to pass to EnTAP config"
    echo "  --qcoverage     <int>   Min. query coverage for similarity searching  [default: 50]"
    echo "  --tcoverage     <int>   Min. target coverage for similarity searching [default: 50]"
    echo "  --evalue        <int>   Evalue cutoff for similarity searching        [default: 1e-5]"
    echo "  --fpkm          <num>   FPKM threshold                                [default: 0.5]"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --debug                 Run the script in debug mode (print all code)"
    echo "  -h                      Print this help message and exit"
    echo "  --help                  Print the help for EnTAP and exit"
    echo "  -v/--version            Print the version of EnTAP and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 -c entap_config.ini -d uniprot_sprot.fa -o results/entap"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "  - EnTAP documentation: https://entap.readthedocs.io/en/latest/"
    echo "  - EnTAP paper: https://onlinelibrary.wiley.com/doi/10.1111/1755-0998.13106"
    echo
}

# Load software
Load_software() {
    set +u
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/entap-0.10.8
    set -u
}

# Print version
Print_version() {
    set +e
    Load_software
    EnTAP --version
    set -e
}

# Print help for the focal program
Print_help_program() {
    Load_software
    EnTAP --help
}

# Print SLURM job resource usage info
Resource_usage() {
    echo
    sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%60,Elapsed,CPUTime | grep -Ev "ba|ex"
    echo
}

# Print SLURM job requested resources
Print_resources() {
    set +u
    echo "# SLURM job information:"
    echo "Account (project):    $SLURM_JOB_ACCOUNT"
    echo "Job ID:               $SLURM_JOB_ID"
    echo "Job name:             $SLURM_JOB_NAME"
    echo "Memory (per node):    $SLURM_MEM_PER_NODE"
    echo "CPUs per task:        $SLURM_CPUS_PER_TASK"
    [[ "$SLURM_NTASKS" != 1 ]] && echo "Nr of tasks:          $SLURM_NTASKS"
    [[ -n "$SBATCH_TIMELIMIT" ]] && echo "Time limit:           $SBATCH_TIMELIMIT"
    echo "======================================================================"
    echo
    set -u
}

# Set the number of threads/CPUs
Set_threads() {
    set +u
    if [[ "$slurm" = true ]]; then
        if [[ -n "$SLURM_CPUS_PER_TASK" ]]; then
            threads="$SLURM_CPUS_PER_TASK"
        elif [[ -n "$SLURM_NTASKS" ]]; then
            threads="$SLURM_NTASKS"
        else 
            echo "WARNING: Can't detect nr of threads, setting to 1"
            threads=1
        fi
    else
        threads=1
    fi
    set -u
}

# Resource usage information
Time() {
    /usr/bin/time -f \
        '\n# Ran the command:\n%C \n\n# Run stats by /usr/bin/time:\nTime: %E   CPU: %P    Max mem: %M K    Exit status: %x \n' \
        "$@"
}   

# Exit upon error with a message
Die() {
    error_message=${1}
    error_args=${2-none}
    
    echo >&2
    echo "=====================================================================" >&2
    printf "$0: ERROR: %s\n" "$error_message" >&2
    echo -e "\nFor help, run this script with the '-h' option" >&2
    echo "For example, 'bash mcic-scripts/qc/fastqc.sh -h'" >&2
    if [[ "$error_args" != "none" ]]; then
        echo -e "\nArguments passed to the script:" >&2
        echo "$error_args" >&2
    fi
    echo -e "\nEXITING..." >&2
    echo "=====================================================================" >&2
    echo >&2
    exit 1
}

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# URL to default config file
CONFIG_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/annot/entap_config.ini

# Option defaults
qcoverage=50    # Also EnTAP default
tcoverage=50    # Also EnTAP default
evalue=1e-05    # Also EnTAP default
fpkm=0.5        # Also EnTAP default

debug=false
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Placeholder defaults
declare -a dbs
db_arg=""
db_dir=""
config_in=""
config_out=""
taxon=""
contam=""
more_args=""

# Parse command-line args
all_args="$*"
count=0
while [ "$1" != "" ]; do
    case "$1" in
        -i | --config_in )  shift && config_in=$1 ;;
        -o | --config_out ) shift && config_out=$1 ;;
        --db_dir )          shift && db_dir=$1 ;;
        --taxon )           shift && taxon=$1 ;;
        --contam )          shift && contam=$1 ;;
        --qcoverage )       shift && qcoverage=$1 ;;
        --tcoverage )       shift && tcoverage=$1 ;;
        --evalue )          shift && evalue=$1 ;;
        --fpkm )            shift && fpkm=$1 ;;
        --more_args )       shift && more_args=$1 ;;
        -v | -v | --version )    Print_version; exit 0 ;;
        -h )                Print_help; exit 0 ;;
        --help )            Print_help_program; exit 0;;
        --debug )           debug=true ;;
        * )                 dbs[count]=$1 && count=$(( count + 1 )) ;;
    esac
    shift
done


# ==============================================================================
#                          OTHER SETUP
# ==============================================================================
# In debugging mode, print all commands
[[ "$debug" = true ]] && set -o xtrace

# Check if this is a SLURM job
[[ -z "$SLURM_JOB_ID" ]] && slurm=false

# Bash script settings
set -euo pipefail

# Load software and set nr of threads
Load_software
Set_threads

# Get the output dir
outdir=$(dirname "$config_out")

# Get the default config file
if [[ "$config_in" = "" ]]; then
    config_in=$(dirname "$config_out")/entap_config_init.ini 
    wget -O "$config_in" -q "$CONFIG_URL"
fi

# Get names of EnTAP output DB files
entap_db="$PWD"/"$db_dir"/bin/entap_database.bin
eggnog_diamond="$PWD"/"$db_dir"/bin/eggnog_proteins.dmnd
eggnog_sql="$PWD"/"$db_dir"/databases/eggnog.db

if [[ ${#dbs[@]} -gt 0 ]]; then
    # Build DIAMOND database arg
    for db in "${dbs[@]}"; do
        db_arg="$db_arg -d $db"
    done

    # Get names of output DIAMOND dbs from FASTA files
    declare -a dbs_out
    count=0
    for db in "${dbs[@]}"; do
        [[ ! -f $db ]] && Die "Input db FASTA $db does not exist!"
        suffix=$(basename "$db" | sed -E 's/.*(.fasta|.fa|.fna|.faa)$/\1/')
        db_out="$db_dir"/bin/$(basename "$db" "$suffix").dmnd
        dbs_out[count]=$db_out && count=$(( count + 1 ))
    done
fi

# Check input
[[ "$taxon" = "" ]] && Die "Please specify a taxon name with --taxon" "$all_args"
[[ "$contam" = "" ]] && Die "Please specify a list of contaminant taxa with --contam" "$all_args"
[[ "$config_out" = "" ]] && Die "Please specify an output config file with --config_out" "$all_args"
[[ "$db_dir" = "" ]] && Die "Please specify an output database dir with --db_dir" "$all_args"
[[ ! -f "$config_in" ]] && Die "Config file $config_in does not exist"

# Report
echo
echo "=========================================================================="
echo "                    STARTING SCRIPT ENTAP_CONFIG.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
echo "Input config file:                $config_in"
echo "Output config file:               $config_out"
echo "Output database dir:              $db_dir"
echo "Number of threads/cores:          $threads"
echo
echo "Taxon name:                       $taxon"
echo "Contaminants:                     $contam"
echo "Query coverage threshold:         $qcoverage"
echo "Target coverage threshold:        $tcoverage"
echo "E-value threshold:                $evalue"
echo "FPKM threshold:                   $fpkm"
[[ $more_args != "" ]] && echo "Other arguments for EnTAP:        $more_args"
if [[ ${#dbs[@]} -gt 0 ]]; then
    echo "Input database FASTA arg:         $db_arg"
    echo "Output DIAMOND databases:         ${dbs_out[*]}"
    echo -e "\n# Listing the input db FASTA files:"
    for db in "${dbs[@]}"; do ls -lh "$db"; done
    echo
fi
echo "=========================================================================="

# Print reserved resources
[[ "$slurm" = true ]] && Print_resources


# ==============================================================================
#                               RUN
# ==============================================================================
# Create the output dir
mkdir -pv "$outdir"/logs
[[ ${#dbs[@]} -gt 0 ]] && mkdir -pv "$db_dir"/diamond_from_fasta

# Modify the config file
echo -e "\n# Now preparing the config file..."
sed -e "s@entap-db-bin=.*@entap-db-bin=$entap_db@" \
    -e "s@eggnog-sql=.*@eggnog-sql=$eggnog_sql@" \
    -e "s@eggnog-dmnd=.*@eggnog-dmnd=$eggnog_diamond@" \
    -e "s/taxon=.*/taxon=$taxon/" \
    -e "s/contam=.*/contam=$contam/" \
    -e "s/qcoverage=.*/qcoverage=$qcoverage/" \
    -e "s/tcoverage=.*/tcoverage=$tcoverage/" \
    -e "s/evalue=.*/evalue=$evalue/" \
    -e "s/fpkm=.*/fpkm=$fpkm/" \
    "$config_in" \
    >"$config_out"
echo "Printing the contents of the output config file:"
echo "=========================================================================="
cat -n "$config_out"
echo "=========================================================================="

# Run EnTAP config
echo -e "\n# Now running EnTAP config..."
Time EnTAP --config \
    --ini "$config_in" \
    --out-dir "$db_dir" \
    -t "$threads" \
    $db_arg \
    $more_args

# Move the DIAMOND db files that were created from the FASTAs
if [[ ${#dbs[@]} -gt 0 ]]; then
    echo "Moving the DIAMOND db files..."
    for db_out in "${dbs_out[@]}"; do
        mv -v "$db_out" "$db_dir"/diamond_from_fasta/
    done
fi


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
echo "# Version used:"
Print_version | tee "$outdir"/logs/version.txt
echo -e "\n# Listing files in the output dir:"
ls -lhd "$PWD"/"$outdir"/*
[[ "$slurm" = true ]] && Resource_usage
echo "# Done with script"
date
