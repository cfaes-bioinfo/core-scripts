#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=4:00:00
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=12
#SBATCH --job-name=checkm
#SBATCH --output=slurm-checkm-%j.out

# PARSE ARGUMENTS --------------------------------------------------------------
## Help function
Help() {
  echo
  echo "$0: Run CheckM to annotate a genome."
  echo
  echo "Syntax: $0 -i <input-dir> -o <output-dir> ..."
  echo
  echo "Required options:"
  echo "-i STRING         Input dir"
  echo "-o STRING         Output dir"
  echo
  echo "Other options:"
  echo "-x STRING         Extension of assembly files          [default: fasta]"
  echo "-a STRING         Other argument(s) to pass to CheckM"
  echo "-h                Print this help message and exit"
  echo
  echo "Example: $0 -i results/assembly -o results/checkm -x fa"
  echo "To submit the OSC queue, preface with 'sbatch': sbatch $0 ..."
  echo
  echo "CheckM documentation: https://github.com/Ecogenomics/CheckM/wiki/"
  echo "CheckM paper: https://www.ncbi.nlm.nih.gov/pmc/articles/PMC4484387/"
  echo
}

## Option defaults
indir=""
outdir=""
extension="fasta"
more_args=""

## Parse command-line options
while getopts ':i:o:x:a:h' flag; do
  case "${flag}" in
    i) indir="$OPTARG" ;;
    o) outdir="$OPTARG" ;;
    x) extension="$OPTARG" ;;
    a) more_args="$OPTARG" ;;
    h) Help && exit 0 ;;
    \?) echo -e "\n## $0: ERROR: Invalid option -$OPTARG\n\n" >&2 && exit 1 ;;
    :) echo -e "\n## $0: ERROR: Option -$OPTARG requires an argument\n\n" >&2 && exit 1 ;;
  esac
done

## Check input
[[ "$indir" = "" ]] && echo "## ERROR: Please specify an input dir with -i" >&2 && exit 1
[[ "$outdir" = "" ]] && echo "## ERROR: Please specify an output dir with -o" >&2 && exit 1
[[ ! -d "$indir" ]] && echo "## ERROR: Input dir (-i) $indir does not exist" >&2 && exit 1


# SETUP ------------------------------------------------------------------------
## Load software
module load python/3.6-conda5.2
source activate /fs/ess/PAS0471/jelmer/conda/checkm-1.2.0

## Bash strict settings
set -euo pipefail

## Report
echo "## Starting script checkm.sh"
date
echo
echo "## Input dir:                            $indir"
echo "## Output dir:                           $outdir"
echo "## FASTA (assembly) file extension:      $extension"
[[ $more_args != "" ]] && echo "## Other arguments to pass to CheckM:    $more_args"
echo "## Listing input FASTA files:"
ls -lh "$indir"/*"$extension"
echo -e "--------------------\n"

## Make output dir
mkdir -p "$outdir"


# RUN CHECKM -------------------------------------------------------------------
checkm lineage_wf \
    -x "$extension" $more_args \
    -t "$SLURM_CPUS_PER_TASK" \
    "$indir" \
    "$outdir"

## Get summary output in TSV file
checkm qa \
    --out_format 2 \
    --tab_table \
    -f "$outdir"/summary.tsv \
    "$outdir"/lineage.ms \
    "$outdir"


# WRAP-UP ----------------------------------------------------------------------
echo -e "\n-------------------------------"
echo "## Listing files in the output dir:"
ls -lh "$outdir"
echo -e "\n## Done with script checkm.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo
