#!/usr/bin/env bash

#SBATCH --account=PAS0471
#SBATCH --time=4:00:00
#SBATCH --cpus-per-task=43
#SBATCH --mem=172G
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=redbean
#SBATCH --output=slurm-redbean-%j.out

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
## Help function
Print_help() {
    echo
    echo "======================================================================"
    echo "                            $0"
    echo "      RUN REDBEAN (WTDBG2) TO ASSEMBLE A GENOME WITH LONG READS"
    echo "======================================================================"
    echo
    echo "USAGE:"
    echo "  sbatch $0 [ -i <input FASTQ(s)> | -I <fofn> ] -o <output FASTA> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "  (Choose one of the input file options: -i or -I)"
    echo "  -i/--infiles        <file>  An input FASTQ file"
    echo "                              Or optionally multiple files, quoted and space-separated"
    echo "  -I/--fofn           <file>  Text file with list of input FASTQ files one per line (fofn)"
    echo "  -o/--outfile        <str>   Output assembly FASTA file (extension '.fa' or '.fasta')"
    echo "  --genome-size       <str>   Genome size estimate, e.g '4.6m' or '1g'"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  --kmer-subsampling  <int>   K-mer subsampling rate, lower nr is less subsampling  [default: 4]"
    echo "                                Less subsampling may improve the assembly for low cov sequencing, but will take longer"
    echo "  --aln-noskip                Even if a read was contained in previous alignment, still align it against other reads"
    echo "                                May improve the assembly for low cov sequencing, but will take longer"
    echo "  --lowcov-edge               For low cov. sequencing: set min edge depth to 2 and use --rescue-low-cov-edges"
    echo "  --more-args         <str>   Quoted string with additional argument(s) to pass to Redbean"
    echo
    echo "UTILITY OPTIONS:"
    echo "  --dryrun                    Dry run: don't execute commands, only parse arguments and report"
    echo "  --debug                     Run the script in debug mode (print all code)"
    echo "  -h                          Print this help message and exit"
    echo "  --help                      Print the help for Smartdenovo and exit"
    echo "  -v/--version                Print the version of Redbean and exit"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "    sbatch $0 -i data/my.fastq -o results/redbean/assembly.fasta --genome_size \"1g\""
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "    - https://github.com/ruanjue/wtdbg2"
    echo "    - https://github.com/ruanjue/wtdbg2/blob/master/README-ori.md"
    echo
}

## Load software
Load_software() {
    module load miniconda3/4.12.0-py39
    [[ -n "$CONDA_SHLVL" ]] && for i in $(seq "${CONDA_SHLVL}"); do source deactivate 2>/dev/null; done
    source activate /fs/ess/PAS0471/jelmer/conda/wtdbg-2.5
}

## Print version
Print_version() {
    Load_software
    wtdbg2 -V
}

## Print help for the focal program
Print_help_program() {
    Load_software
    wtdbg2 --help
}

## Print SLURM job resource usage info
Resource_usage() {
    ${e}sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%60,Elapsed,CPUTime,MaxVMSize | \
        grep -Ev "ba|ex"
}

## Print SLURM job requested resources
Print_resources() {
    set +u
    echo "# SLURM job information:"
    echo "Account (project):    $SLURM_JOB_ACCOUNT"
    echo "Job ID:               $SLURM_JOB_ID"
    echo "Job name:             $SLURM_JOB_NAME"
    echo "Memory (MB per node): $SLURM_MEM_PER_NODE"
    echo "CPUs per task:        $SLURM_CPUS_PER_TASK"
    [[ "$SLURM_NTASKS" != 1 ]] && echo "Nr of tasks:          $SLURM_NTASKS"
    [[ -n "$SBATCH_TIMELIMIT" ]] && echo "Time limit:           $SBATCH_TIMELIMIT"
    echo "======================================================================"
    echo
    set -u
}

## Set the number of threads/CPUs
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

## Resource usage information
Time() {
    /usr/bin/time -f \
        '\n# Ran the command:\n%C \n\n# Run stats by /usr/bin/time:\nTime: %E   CPU: %P    Max mem: %M K    Exit status: %x \n' \
        "$@"
}   

## Exit upon error with a message
Die() {
    error_message=${1}
    error_args=${2-none}
    
    echo
    echo "====================================================================="
    printf "$0: ERROR: %s\n" "$error_message" >&2
    echo -e "\nFor help, run this script with the '-h' option"
    echo "For example, 'bash mcic-scripts/qc/fastqc.sh -h"
    if [[ "$error_args" != "none" ]]; then
        echo -e "\nArguments passed to the script:"
        echo "$error_args"
    fi
    echo -e "\nEXITING..." >&2
    echo "====================================================================="
    echo
    exit 1
}


# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
## Option defaults
read_type=ont   #  "rs" for PacBio RSII, "sq" for PacBio Sequel, "ccs" for PacBio CCS reads and "ont" for Oxford Nanopore
kmer_subsampling=4
aln_noskip=false && aln_skip_arg=""
lowcov_edge=false && edge_arg=""

debug=false
dryrun=false && e=""
slurm=true


# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
## Placeholder defaults
declare -a infiles
fofn=""
outfile=""
more_args=""
genome_size=""
more_args=""
infile_arg=""

## Parse command-line args
all_args="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -i | --infiles )        shift && IFS=" " read -r -a infiles <<< "$1" ;;
        -I | --fofn )           shift && fofn=$1 ;;
        -o | --outfile )        shift && outfile=$1 ;;
        --genome-size )         shift && genome_size=$1 ;;
        --more-args )           shift && more_args=$1 ;;
        --kmer-subsampling )    shift && kmer_subsampling=$1 ;;
        --aln-noskip )          aln_noskip=true ;;
        --lowcov-edge )         lowcov_edge=true ;;
        --debug )               debug=true ;;
        --dryrun )              dryrun=true ;;
        -v | -v | --version )        Print_version; exit ;;
        -h )                    Print_help; exit 0;;
        --help )                Print_help_program; exit 0;;
        * )                     Print_help; Die "Invalid option $1" ;;
    esac
    shift
done


# ==============================================================================
#                          OTHER SETUP
# ==============================================================================
## In debugging mode, print all commands
[[ "$debug" = true ]] && set -o xtrace

## Check if this is a SLURM job
[[ -z "$SLURM_JOB_ID" ]] && slurm=false

## Load software and set nr of threads
[[ "$dryrun" = false ]] && Load_software
Set_threads

## Bash strict settings
set -euo pipefail

## Check input
[[ ${#infiles[@]} = 0 && "$fofn" = "" ]] && Die "Please specify input files with -i or -I" "$all_args"
[[ $outfile = "" ]] && Die "Please specify an output prefix with -o" "$all_args"
[[ $genome_size = "" ]] && Die "Please specify a genome size with -s" "$all_args"

## Build other args
[[ "$aln_noskip" = true ]] && aln_skip_arg="--aln-noskip"
[[ "$lowcov_edge" = true ]] && edge_arg="--edge-min 2 --rescue-low-cov-edges"

## Define prefix and output dir
outdir=$(dirname "$outfile")
file_ext=$(echo "$outfile" | sed -E 's/.*(.fasta|.fna|.fa)$/\1/')
out_prefix=${outfile/"$file_ext"/}

## If a FOFN was provided, read file list into an array
[[ "$fofn" != "" ]] && mapfile -t infiles <"$fofn"

## Build the input file arg
for infile in "${infiles[@]}"; do
    infile_arg="$infile_arg -i $infile"
done

## Report
echo
echo "=========================================================================="
echo "               STARTING SCRIPT REDBEAN.SH"
date
echo "=========================================================================="
echo "All arguments to this script:     $all_args"
[[ "$fofn" != "" ]] && echo "File with list of FASTQs (fofn):  $fofn"
echo "Input files:                      ${infiles[*]}"
echo "Number of input files:            ${#infiles[*]}"
echo "Input file argument:              $infile_arg"
echo "Output file:                      $outfile"
echo "Genome size:                      $genome_size"
[[ $more_args != "" ]] && echo "Other arguments for Redbean:      $more_args"
echo
echo "Listing the input files:"
for infile in "${infiles[@]}"; do
    [[ ! -f $infile ]] && Die "Input file $infile does not exist!"
    ls -lh "$infile"
done
[[ $dryrun = true ]] && echo -e "\nTHIS IS A DRY-RUN"
echo "=========================================================================="

## Print reserved resources
[[ "$slurm" = true ]] && Print_resources


# ==============================================================================
#                               RUN
# ==============================================================================
if [[ "$dryrun" = false ]]; then
    
    ## Create the output directory
    mkdir -p "$outdir"/logs

    echo -e "\n## Now running 'wtdbg2'..."
    Time wtdbg2 \
        $infile_arg \
        -fo "$out_prefix" \
        -x $read_type \
        -g "$genome_size" \
        --kmer-subsampling "$kmer_subsampling" \
        -t "$threads" \
        -f \
        $aln_skip_arg $edge_arg $more_args
    
    echo -e "\n## Now running the consensus step..."
    Time wtpoa-cns \
        -i "$out_prefix".ctg.lay.gz \
        -fo "$out_prefix".ctg.fa \
        -t "$threads"

    ## Copy assembly FASTA
    echo -e "\n# Copying the assembly FASTA file:"
    cp -v "$out_prefix".ctg.fa "$outfile"

fi

## -f forces overwrite

## Low coverage options:
# - By default, wtdbg2 samples a fourth of all k-mers by their hashcodes.
#   For data of relatively low coverage, you may increase this sampling rate by reducing -S.
# - Option -A/--aln-noskip also helps relatively low coverage data at the cost of performance. 
#  - For low coverage: Try --edge-min 2 --rescue-low-cov-edges.


# ==============================================================================
#                               WRAP-UP
# ==============================================================================
echo
echo "========================================================================="
if [[ "$dryrun" = false ]]; then
    echo "# Version used:"
    Print_version | tee "$outdir"/logs/version.txt
    echo -e "\n# Listing the final assembly file:"
    ls -lhd "$PWD"/"$outfile"
    echo
    [[ "$slurm" = true ]] && Resource_usage
    echo
fi
echo "# Done with script"
date
