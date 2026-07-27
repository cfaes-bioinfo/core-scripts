#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --job-name=sistr
#SBATCH --output=slurm-sistr-%j.out

# FUNCTIONS --------------------------------------------------------------------
## Help function
function Print_help() {
    echo
    echo "=================================================================================================="
    echo "      $0: Run SISTR (sistr_cmd) for Salmonella In Silico Typing"
    echo "=================================================================================================="
    echo
    echo "REQUIRED OPTIONS:"
    echo "  -i / --indir DIR              Input directory with one or more genomes in FASTA format"
    echo "                                  - The extensions .fasta, .fa, and .fna are recognized"
    echo "                                  - The script will look for FASTA files recursively"
    echo "  -o / --outdir DIR             Output directory for workflow results"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "  -a / --more_args STRING       Additional arguments to pass to sistr"
    echo "                                  - Use as follows (quote the entire string!):"
    echo "                                    $0 --more_args \"--tmp-dir /tmp\""
    echo "                                    $0 --more_args \"--use-full-cgmlst-db\""
    echo
    echo "UTILITY OPTIONS:"
    echo "  -h / --help                   Print this help message and exit"
    echo "  -v / --version                Print SISTR's version, the location of the program, and exit"
    echo
    echo "HARDCODED PARAMETERS:"
    echo "  This script uses the following names for the output files within the specified output dir:"
    echo "    - 'sistr-output.tab'        SISTR serovar prediction "
    echo "    - 'allele-results.json'     Output JSON file of allele sequences and info"
    echo "    - 'novel-alleles.fasta'     Output FASTA file destination of novel cgMLST alleles from input genomes"
    echo "    - 'cgmlst-profiles.csv'     cgMLST allelic profiles"
    echo
    echo "DEFAULT SLURM/SBATCH SETTINGS:"
    echo "  - Project:                    PAS0471"
    echo "  - Time (in hours):            1"
    echo "  - Number of cores:            4"
    echo "  - Memory:                     16 GB"
    echo "  You can overried these defaults using sbatch arguments when submitting the script, e.g.:"
    echo "      sbatch --account=PAS8855 --time=24:00:00 -c 16 --mem=50G $0 [...]"
    echo
    echo "EXAMPLE COMMANDS:"
    echo "  sbatch $0 --indir results/assemblies --outdir results/sistr"
    echo "  sbatch $0 --indir results/assemblies --outdir results/sistr --more_args \"--use-full-cgmlst-db\""
    echo
    echo " DOCUMENTATION:"
    echo "- https://github.com/phac-nml/sistr_cmd"
    echo
}

## Exit upon error with a message
function Die() {
    printf "\n$0: ERROR: %s\n" "$1" >&2
    echo -e "Exiting\n" >&2
    exit 1
}

## Load Nextflow
function Load_software() {
    module load miniconda3/4.12.0-py39
    source activate /fs/ess/PAS0471/jelmer/conda/sistr-1.1.1
}

## Print version
function Print_version {
    sistr --version
    whereis sistr
}


# PARSE COMMAND-LINE OPTIONS ---------------------------------------------------
indir=""
outdir=""
more_args=""

## Parse command-line options
while [ "$1" != "" ]; do
    case "$1" in
        -i | --indir )          shift && indir=$1 ;;
        -o | --outdir )         shift && outdir=$1 ;;
        -a | --more_args )      shift && more_args=$1 ;;
        -h | --help )           Print_help; exit ;;
        -v | -v | --version )        Load_software && Print_version; exit ;;
        * )                     Print_help; Die "Invalid option $1" ;;
    esac
    shift
done

# OTHER SETUP ------------------------------------------------------------------
## Load Conda environment
Load_software

## Bash strict settings
set -ueo pipefail

## Check input
[[ "$indir" = "" ]] && Die "Please specify an input dir with -i/--indir"
[[ "$outdir" = "" ]] && Die "Please specify an output dir with -o/--outdir"
[[ ! -d "$indir" ]] && Die "Input dir $indir does not exist"

## Report
echo
echo "=========================================================================="
echo "                   STARTING SCRIPT SISTR.SH"
date
echo "=========================================================================="
echo "Input dir:                       $indir"
echo "Output dir:                      $outdir"
[[ "$more_args" != "" ]] && echo "Additional arguments:            $more_args"
echo "=========================================================================="
echo


# MAIN -------------------------------------------------------------------------
## Make output dir if needed
mkdir -p "$outdir"/logs

## Find input files
genomes=( $(find "$indir" -name "*fasta" -or -name "*fa" -or -name "*fna") )
echo "## Number of genomes found:      ${#genomes[@]}"
echo "## Genome files found:"
echo "${genomes[@]}" | tr " " "\n"

## Run
echo -e "\n## Running SISTR..."
set -o xtrace
sistr \
    --output-format tab \
    --output-prediction "$outdir"/sistr-output.tab \
    --alleles-output "$outdir"/allele-results.json \
    --novel-alleles "$outdir"/novel-alleles.fasta \
    --cgmlst-profiles "$outdir"/cgmlst-profiles.csv \
    --qc \
    -vv \
    --threads "$SLURM_CPUS_PER_TASK" \
    "${genomes[@]}"
set +o xtrace


# WRAP UP ----------------------------------------------------------------------
echo -e "\n-------------------------------"
echo "## SISTR version used:"
Print_version | tee "$outdir"/logs/version.txt
echo "## Listing files in the output dir:"
ls -lh "$outdir"
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo
echo "## Done with script"
date
echo
