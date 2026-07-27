#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=12:00:00
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --mail-type=FAIL
#SBATCH --job-name=justorthologs
#SBATCH --output=slurm-justorthologs-%j.out

# https://academic.oup.com/bioinformatics/article/35/4/546/5063405
# https://github.com/ridgelab/JustOrthologs/blob/master/README_WRAPPER

# Load the software
module load miniconda3
conda activate /fs/ess/PAS0471/jelmer/conda/justorthologs-0.0.2

dmel_gff=data/ref/dmel/dmel-all-r6.54_nofasta.gff
dmel_fa=data/ref/dmel/dmel-all-r6.54_fromgff.fa
aedes_fa=data/ref/aedes/VectorBase-49_AaegyptiLVP_AGWG_Genome.fasta
aedes_gff=data/ref/aedes/VectorBase-49_AaegyptiLVP_AGWG.gff

# 1. Create CDS FASTAs
sed -E 's/(>[^ ]+) .*/\1/' "$dmel_fa" > dmel.fa
gff3_parser.py -g "$dmel_gff" -f dmel.fa -o dmel_extract.fasta
sed -E 's/(>[^ ]+) .*/\1/' "$aedes_fa" > aedes.fa
gff3_parser.py -g "$aedes_gff" -f aedes.fa -o aedes_extract.fasta

# 2. Filter FASTAs
getNoException.py -i aedes_extract.fasta -o aedes_filt.fasta
getNoException.py -i dmel_extract.fasta -o dmel_filt.fasta

# 3. Sort FASTAs
bash sortFastaBySeqLen.sh aedes_filt.fasta aedes_sort.fasta
bash sortFastaBySeqLen.sh dmel_filt.fasta dmel_sort.fasta

# 4. Run justOrthologs.py
fa1=aedes_sort.fasta
fa2=dmel_sort.fasta
justOrthologs.py -q $fa1 -s $fa2 -o justortho.txt -t 4 -c

# Try the wrapper - not working
#wrapper.py \
#    -r1 "$dmel_fa" -g1 "$dmel_gff" \
#    -r2 "$aedes_fa" -g2 "$aedes_gff" \
#    -c -t 1 -all -k -o JUSTORTHO_TEST
