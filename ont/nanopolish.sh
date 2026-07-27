#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=32
#SBATCH --output=slurm-nanopolish-%j.out


# SETUP ------------------------------------------------------------------------
## Command-line args
genome_in=$1
reads=$2
outdir=$3

## Input checks
[[ "$#" != 3 ]] && echo "## ERROR: Please provide 3 arguments; you provided $#" && exit 1
[[ ! -f "$genome_in" ]] && echo "## ERROR: Input genome FASTA file $genome_in does not exist" && exit 1
[[ ! -f "$reads" ]] && echo "## ERROR: Input genome reads file $reads does not exist" && exit 1

## Software
module load python/3.6-conda5.2
NANOPOLISH_ENV=/fs/ess/PAS0471/jelmer/conda/nanopolish-0.13.2
MINIMAP_ENV=/fs/ess/PAS0471/jelmer/conda/minimap2-2.24

## Bash strict settings
#set -euo pipefail # Script stops after nanopolish variants --consensus, not clear why

## Derived parameters
fileID=$(basename "$genome_in" | sed -E 's/.fas?t?a?//')
bam_out="$outdir"/"$fileID".bam
vcf_dir="$outdir"/vcf
genome_out="$outdir"/"$fileID".fa

## Report
echo -e "\n## Starting script nanopolish.sh"
date
echo
echo "## Input genome FASTA:            $genome_in"
echo "## Input read:                    $reads"
echo "## Output directory:              $outdir"
echo
echo "## Output genome FASTA:           $genome_out"
echo -e "-------------------------------\n"


## Make output dirs
mkdir -p "$outdir" "$vcf_dir"


# RUN THE NANOPOLISH PIPELINE --------------------------------------------------
## Map reads to the original draft genome
echo "## Now mapping reads to the input draft genome..."
source activate "$MINIMAP_ENV"

minimap2 -ax map-ont \
    -t 8 \
    "$genome_in" \
    "$reads" | \
    samtools sort -o "$bam_out" -T reads.tmp -

## Index the BAM file (samtools is included in the Minimap2-env)
echo -e "\n## Now indexing the BAM file..."
samtools index "$bam_out"

## Step 4 - Run Nanopolish (in parallel for 50-kbp sections of the genome)
echo -e "\n## Now running Nanopolish variants --consensus..."
source activate "$NANOPOLISH_ENV"

nanopolish_makerange.py "$genome_in" | \
    parallel --results "$outdir"/nanopolish.results -P 8 \
        nanopolish variants --consensus \
            -o "$vcf_dir"/polished.{1}.vcf \
            -w {1} \
            -r "$genome_in" \
            -b "$bam_out" \
            -g "$genome_in" \
            -t 4 \
            --min-candidate-frequency 0.1

## Combine the VCF files into a polished genome FASTA
echo -e "\n## Now running Nanopolish vcf2fasta..."
nanopolish vcf2fasta \
    -g "$genome_in" \
    "$vcf_dir"/polished.*.vcf > "$genome_out"


# WRAP UP ----------------------------------------------------------------------
echo -e "\n## Listing output files:"
ls -lh "$outdir"
echo -e "\n## Done with script nanopolish.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo


# ALT - MAP WITH BWA -----------------------------------------------------------
#BWA_ENV=/fs/ess/PAS0471/jelmer/conda/bwa-0.7.17
#source activate "$BWA_ENV"
#bwa index "$genome_in"
#bwa mem -x ont2d \

## Nanopolish docs
#? https://github.com/jts/nanopolish
#? https://nanopolish.readthedocs.io/en/latest/quickstart_consensus.html#