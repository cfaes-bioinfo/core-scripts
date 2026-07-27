#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --mem=16G
#SBATCH --cpus-per-task=12
#SBATCH --job-name=khmer
#SBATCH --output=slurm-khmer_norm-%j.out


# PARSE ARGS -------------------------------------------------------------------
## Help function
Help() {
  echo
  echo "$0: Normalize RNAseq reads prior to assembly with khmer"
  echo
  echo "Syntax: $0 -i <input-dir> -o <output-dir> ..."
  echo
  echo "Required options:"
  echo "-i STRING     Input directory with FASTQ files"
  echo "-o STRING     Output directory"
  echo
  echo "Other options:"
  echo "-h            Print this help message and exit"
  echo
  echo "Example: $0 -i data/fastq/ -o results/khmer"
  echo "To submit to the OSC queue, preface with 'sbatch': sbatch $0 ..."
  echo
  echo "khmer docs:"
  echo "   - https://khmer.readthedocs.io/en/latest/"
  echo "   - https://khmer.readthedocs.io/en/stable/user/scripts.html?highlight=normalization#scripts-diginorm"
}

## Default parameter values
indir=""
outdir=""

## Get parameter values
while getopts ':i:o:h' flag; do
    case "${flag}" in
    i) indir="$OPTARG" ;;
    o) outdir="$OPTARG" ;;
    h) Help && exit 0 ;;
    \?) echo "## $0: ERROR: Invalid option -$OPTARG" >&2 && exit 1 ;;
    :) echo "## $0: ERROR: Option -$OPTARG requires an argument." >&2 && exit 1 ;;
    esac
done

## Report
echo -e "\n## Starting script khmer_norm.sh"
date
echo

## Check parameter values
[[ ! -d "$indir" ]] && echo "## ERROR: Input dir (-i) $indir does not exist" >&2 && exit 1


# SOFTWARE ---------------------------------------------------------------------
## Load software
module load python/3.6-conda5.2
source activate /fs/ess/PAS0471/jelmer/conda/khmer-3.0


# OTHER SETUP ------------------------------------------------------------------ 
## Bash strict mode
set -euo pipefail

## Report
echo "## Input dir:                            $indir"
echo "## Output dir:                           $outdir"
echo -e "-------------------------------\n"

## Create output dir if needed
mkdir -p "$outdir"

## Make input path absolute
[[ ! $indir =~ ^/ ]] && indir="$PWD"/"$indir"

# RUN KHMER ---------------------------------------------------------------
cd "$outdir" || exit

echo "## Starting khmer normalization script..."
normalize-by-median.py \
    -p \
    --ksize 20 \
    --cutoff 20 \
    -M 16G \
    -s norm.kh "$indir"/*fastq.gz

echo -e "\n## Starting khmer filter-abund script..."
filter-abund.py \
    --variable-coverage \
    --normalize-to 18 \
    --threads 6 \
    norm.kh *.keep


# WRAP-UP ----------------------------------------------------------------------
echo -e "\n-------------------------------"
echo "## Listing files in the output dir:"
ls -lh

echo -e "\n## Done with script khmer_norm.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo


## Alternative software: ORNA
# - Paper: https://www.nature.com/articles/s41598-019-41502-9
# - GitHub: https://github.com/SchulzLab/ORNA
# - Conda: https://anaconda.org/bioconda/orna