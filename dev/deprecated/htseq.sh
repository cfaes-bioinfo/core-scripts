#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=1:00:00
#SBATCH --ntasks-per-node=8
#SBATCH --job-name=htseq
#SBATCH --out=slurm-htseq-%j.out

# PARSE OPTIONS ----------------------------------------------------------------
## Help function
Help() {
    echo
    echo "$0: Create a matrix with per-gene read counts for a directory of BAM files using HtSeq."
    echo
    echo "Syntax: $0 -i <input-FASTA> -o <output-dir> -a <gff-file> ..."
    echo
    echo "Required options:"
    echo "    -i DIR        Input directory with BAM files"
    echo "    -a FILE       Input reference annotation (GFF/GTF) file"
    echo "    -o FILE       Output file with count matrix (e.g. 'counts.txt')"
    echo
    echo "Other options:"
    echo "    -t STRING     Feature type to count                        [default: 'exon']"
    echo "                  (This should correspond to a value in the 3rd column in the GFF/GTF file)"
    echo "    -g STRING     Identifier of the feature type               [default: 'Name']"
    echo "                  (This should correspond to the key for the desired feature type (e.g. gene) in the last column in the GFF/GTF file)"
    echo "    -h            Print this help message and exit"
    echo
    echo "Example: $        0 -i results/bam -o results/htseq -a refdata/my_genome.gff"
    echo "To submit the OSC queue, preface with 'sbatch': sbatch $0 ..."
    echo
}

## Option defaults
indir=""
outfile=""
gff=""
feature_type=exon      # Same default as HTseq
id_attr=Name

## Parse command-line options
while getopts ':i:o:a:t:g:h' flag; do
    case "${flag}" in
        i) indir="$OPTARG" ;;
        o) outfile="$OPTARG" ;;
        a) gff="$OPTARG" ;;
        t) feature_type="$OPTARG" ;;
        g) id_attr="$OPTARG" ;;
        h) Help && exit 0 ;;
        \?) echo -e "\n## $0: ERROR: Invalid option -$OPTARG\n\n" >&2 && exit 1 ;;
        :) echo -e "\n## $0: ERROR: Option -$OPTARG requires an argument\n\n" >&2 && exit 1 ;;
    esac
done

# SETUP ---------------------------------------------------------------------
## Load software
module load miniconda3
source activate /fs/ess/PAS0471/jelmer/conda/htseq-2.0.2
conda activate --stack /fs/ess/PAS0471/jelmer/conda/samtools

## Strict bash settings
set -euo pipefail

## Process parameters
outdir=$(dirname "$outfile")

## Check inputs
[[ ! -d "$indir" ]] && echo "## ERROR: Input dir (-d) $indir does not exist" >&2 && exit 1
[[ ! -f "$gff" ]] && echo "## ERROR: Input file GFF (-a) $gff does not exist" >&2 && exit 1

## Report
echo
echo "## Starting script htseq.sh"
date
echo
echo "## BAM input dir (-i):              $indir"
echo "## Output file (-o):                $outfile"
echo "## Annotation (GTF/GFF) file (-a):  $gff"
echo "## ID type:                         $feature_type"
echo "## ID attribute (aggregation ID):   $id_attr"
echo
echo "## Number of BAM files:             $(find "$indir"/*bam | wc -l)"
echo -e "-------------------\n"

## Make output dir if needed
mkdir -p "$outdir"


# MAIN -------------------------------------------------------------------------
## Index BAM files if needed
for bam in "$indir"/*bam; do
    [[ ! -f "$bam".bai ]] && echo "Indexing $bam..." && samtools index "$bam"
done

## Run HTseq
htseq-count \
    --nprocesses "$SLURM_NTASKS" \
    --type "$feature_type" \
    --idattr "$id_attr" \
    --stranded reverse \
    --minaqual 10 \
    --format bam \
    --order pos \
    --max-reads-in-buffer=30000000 \
    "$indir"/*bam \
    "$gff" \
    > "$outfile"


# WRAP UP ----------------------------------------------------------------------
echo -e "\n------------------------"
echo "## Listing output file:"
ls -lh "$outfile"
echo
echo "## Done with script htseq.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo
