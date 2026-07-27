#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --ntasks=1
#SBATCH --job-name=qualimap
#SBATCH --output=slurm-qualimap-%j.out


# PARSE ARGS -------------------------------------------------------------------
## Help function
Help() {
  echo
  echo "## $0: Run 'qualimap rnaseq' for a BAM file."
  echo
  echo "## Syntax: $0 -i <bam> -a <gff> -o <outdir> ..."
  echo
  echo "## Required options:"
  echo "## -i STRING        Input BAM file"
  echo "## -a STRING        Input annotation file in GTF format (not GFF!)"
  echo "## -o STRING        Output directory"
  echo
  echo "## Other options:"
  echo "## -l STRING        Library type           [default: 'strand-specific-reverse']"
  echo "##                  One of: 'strand-specific-forward', 'strand-specific-reverse' or 'non-strand-specific'"
  echo "## -h               Print this help message and exit"
  echo
  echo "## Example: $0 -i results/bam/A.bam -o results/qualimap -a data/my_annot.gff"
  echo "## To submit to the OSC queue, preface with 'sbatch': sbatch $0 ..."
  echo
}

## Default parameter values
bam=""
annot=""
outdir=""
libtype=strand-specific-reverse

## Get command-line parameter values
while getopts ':i:a:o:l:h' flag; do
    case "${flag}" in
    i) bam="$OPTARG" ;;
    a) annot="$OPTARG" ;;
    o) outdir="$OPTARG" ;;
    l) libtype="$OPTARG" ;;
    h) Help && exit 0 ;;
    \?) echo "## $0: ERROR: Invalid option -$OPTARG" >&2 && exit 1 ;;
    :) echo "## $0: ERROR: Option -$OPTARG requires an argument." >&2 && exit 1 ;;
    esac
done


# OTHER SETUP ------------------------------------------------------------------
## Report
echo -e "\n## Starting script qualimap.sh"
date
echo

## Test parameter values
[[ ! -f "$bam" ]] && echo "## ERROR: Input BAM file (-i) $bam does not exist" >&2 && exit 1
[[ ! -f "$annot" ]] && echo "## ERROR: Input annotation file (-a) $annot does not exist" >&2 && exit 1

## Load software
module load python/3.6-conda5.2
source activate /fs/ess/PAS0471/jelmer/conda/qualimap-env

## Bash strict mode
set -euo pipefail

## Assign output dir that includes sample ID
sampleID=$(basename "$bam" .bam)
outdir_full="$outdir"/"$sampleID"

## Report
echo "## Input BAM file:                     $bam"
echo "## Input annotation (GFF/GTF) file:    $annot"
echo "## Output directory:                   $outdir_full"
echo "## Library type:                       $libtype"
echo

## Create output dir if needed
mkdir -p "$outdir_full"


# RUN QUALIMAP -----------------------------------------------------------------
unset DISPLAY

qualimap rnaseq \
    -bam "$bam" \
    -gtf "$annot" \
    -outdir "$outdir_full" \
    -p "$libtype" \
    --java-mem-size=16G

#-a proportional \
#? -a: Counting algorithm - uniquely-mapped-reads(default) or proportional (each multi-mapped read is weighted according to the number of mapped locations)


# WRAP UP ----------------------------------------------------------------------
echo -e "\n--------------------------"
echo "## Listing file in the output dir:"
ls -lh "$outdir_full"
echo -e "\n## Done with script qualimap.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo
