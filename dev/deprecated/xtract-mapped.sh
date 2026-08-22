#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --output=slurm-xtract-mapped-%j.out

## Report
echo -e "\n## Starting script xtract-mapped.sh..."
date
echo

## Process args
bam_in=$1
bam_out=$2

## Load software
module load python/3.6-conda5.2
source activate /fs/ess/PAS0471/jelmer/conda/samtools

## Output files
outdir=$(basename "$bam_out")
mkdir -p "$outdir"

## Report
echo "## Input BAM file:      $bam_in"
echo "## Output BAM file:     $bam_out"
echo
echo "## Listing intput file:"
ls -lh "$bam_in"
echo


# MAIN -------------------------------------------------------------------------
## Convert BAM to FASTQ
samtools view -b -F 4 "$bam_in" > "$bam_out"


# WRAP UP ----------------------------------------------------------------------
## Report
echo -e "\n## Listing output file:"
ls -lh "$bam_out"
echo -e "\n## Done with script xtract-mapped.sh"
date
echo
