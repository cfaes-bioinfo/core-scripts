#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --ntasks=1
#SBATCH --job-name=rseqc
#SBATCH --output=slurm-rseqc-%j.out


# PARSE ARGS -------------------------------------------------------------------
## Help function
Help() {
  echo
  echo "## $0: Run RSeQC for a BAM file."
  echo
  echo "## Syntax: $0 -i <bam> -a <gff> -o <outdir> ..."
  echo
  echo "## Required options:"
  echo "## -i STRING        Input BAM file"
  echo "## -a STRING        Input annotation file in BED format (not GFF/GTF!)"
  echo "## -o STRING        Output directory"
  echo
  echo "## Other options:"
  echo "## -h               Print this help message and exit"
  echo
  echo "## Example: $0 -i results/bam/A.bam -o results/rseqc -a data/my_annot.bed"
  echo "## To submit to the OSC queue, preface with 'sbatch': sbatch $0 ..."
  echo
}

## Default parameter values
bam=""
annot=""
outdir=""

## Get command-line parameter values
while getopts ':i:a:o:h' flag; do
    case "${flag}" in
    i) bam="$OPTARG" ;;
    a) annot="$OPTARG" ;;
    o) outdir="$OPTARG" ;;
    h) Help && exit 0 ;;
    \?) echo "## $0: ERROR: Invalid option -$OPTARG" >&2 && exit 1 ;;
    :) echo "## $0: ERROR: Option -$OPTARG requires an argument." >&2 && exit 1 ;;
    esac
done


# OTHER SETUP ------------------------------------------------------------------
## Report
echo -e "\n## Starting script rseqc.sh"
date
echo

## Test parameter values
[[ ! -f "$bam" ]] && echo "## ERROR: Input BAM file (-i) $bam does not exist" >&2 && exit 1
[[ ! -f "$annot" ]] && echo "## ERROR: Input annotation file (-a) $annot does not exist" >&2 && exit 1

## Load software
module load python/3.6-conda5.2
source activate /fs/ess/PAS0471/jelmer/conda/rseqc-env

## Bash strict mode
set -euo pipefail

## Infer prefix
sampleID=$(basename "$bam" .bam)
prefix="$outdir"/"$sampleID"

## Report
echo "## Input BAM file:                                  $bam"
echo "## Input annotation (BED) file:                     $annot"
echo "## Output directory:                                $outdir"
echo "## Inferred sample ID (used as output prefix):      $sampleID"
echo

## Create output dir if needed
mkdir -p "$outdir"


# RUN RSEQC -----------------------------------------------------------------
echo -e "\n## Now running infer_experiment.py..." && date
infer_experiment.py \
    -i "$bam" \
    -r "$annot" \
    > "$prefix".infer_experiment.txt

echo -e "\n## Now running read_distribution.py..." && date
read_distribution.py \
    -i "$bam" \
    -r "$annot" \
    > "$prefix".read_distribution.txt    

echo -e "\n## Now running junction_annotation.py..." && date
junction_annotation.py \
    -i "$bam" \
    -r "$annot" \
    -o "$prefix" \
    2> "$prefix".junction_annotation.log

echo -e "\n## Now running inner_distance.py..." && date
inner_distance.py \
    -i "$bam" \
    -r "$annot" \
    -o "$prefix" \
    > "$prefix".inner_distance.log

echo -e "\n## Now running junction_saturation.py..." && date
junction_saturation.py \
    -i "$bam" \
    -r "$annot" \
    -o "$prefix"

echo -e "\n## Now running read_duplication.py..." && date
read_duplication.py \
    -i "$bam" \
    -o "$prefix" \

echo -e "\n## Now running bam_stat.py..." && date
bam_stat.py \
    -i "$bam" \
    > "$prefix".bam_stat.txt


# WRAP UP ----------------------------------------------------------------------
echo -e "\n--------------------------"
echo "## Listing file in the output dir:"
ls -lh "$outdir"
echo -e "\n## Done with script rseqc.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo



