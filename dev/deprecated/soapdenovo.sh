#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=12
#SBATCH --mem=50G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=soapdenovo
#SBATCH --output=slurm-soapdenovo-%j.out


# PARSE ARGUMENTS --------------------------------------------------------------
## Help function
Help() {
  echo
  echo "$0: Run SOAPdenovo-trans to create a transcriptome assembly."
  echo
  echo "Syntax: $0 -i <genome-FASTA> -o <output-dir> ..."
  echo
  echo "Required options:"
  echo "    -i STRING         Genome (nucleotide) FASTA file"
  echo "    -o STRING         Output dir"
  echo
  echo "Other options:"
  echo "    -a STRING         Other argument(s) to pass to SOAPdenovo"
  echo "    -h                Print this help message"
  echo
  echo "Example: $0 -i data/fastq -o results/soapdenovo"
  echo "To submit the OSC queue, preface with 'sbatch': sbatch $0 ..."
  echo
  echo "SOAPdenovo-trans documentation: https://github.com/aquaskyline/SOAPdenovo-Trans"
  echo "SOAPdenovo-trans paper: https://pubmed.ncbi.nlm.nih.gov/24532719/"
  echo
}

## Option defaults
indir=""
outdir=""
more_args=""
kmer_size=13
insert_size=200
max_readlen=150

## Parse command-line options
while getopts ':i:o:k:a:h' flag; do
  case "${flag}" in
    i) indir="$OPTARG" ;;
    o) outdir="$OPTARG" ;;
    k) kmer_size="$OPTARG" ;;
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
## Software
module load python/3.6-conda5.2
source activate /fs/ess/PAS0471/jelmer/conda/soapdenovo-trans-1.0.4

## Bash strict mode
set -euo pipefail

## Pick SOAPdenovo executable, depending on kmer size
[[ $kmer_size -lt 32 ]] && soapdenovo=SOAPdenovo-Trans-31mer
[[ $kmer_size -gt 32 ]] && soapdenovo=SOAPdenovo-Trans-127mer

## Other variables
config="$outdir"/config.txt

## Make output dir
mkdir -p "$outdir"

## Report
echo
echo "## Starting script soapdenovo.sh"
date
echo
echo "## Input dir:                            $indir"
echo "## Output dir:                           $outdir"
echo
echo "## Config file:                          $config"
echo "## Kmer size:                            $kmer_size"
echo "## Max read length:                      $max_readlen"
echo "## Mean insert size                      $insert_size"
[[ "$more_args" != "" ]] &&echo "## Other arguments for SOAPdenovo:       $more_args"
echo -e "--------------------\n"


# CREATE CONFIG FILE -----------------------------------------------------------
echo "## Creating config file..."
cat > "$config" <<EOF
max_rd_len=$max_readlen
[LIB]
rd_len_cutof=$max_readlen
avg_ins=$insert_size
reverse_seq=0
asm_flags=3
map_len=32
EOF

for fq in "$indir"/*fastq.gz "$indir"/*fq.gz; do
    [[ $fq =~ "_R1" ]] && echo "q1=$fq" >> "$config"
    [[ $fq =~ "_R2" ]] && echo "q2=$fq" >> "$config"
done

echo "## Printing contents of config file:"
cat "$config"


# RUN SOAPDENOVO ---------------------------------------------------------------
echo -e "\n## Now running SOAPdenovo..."
"$soapdenovo" all \
    -s "$config" \
    -K "$kmer_size" \
    -p "$SLURM_CPUS_PER_TASK" \
    -o "$outdir"         # May need to include a file prefix


# WRAP-UP ----------------------------------------------------------------------
echo -e "\n-------------------------------"
echo "## Listing files in the output dir:"
ls -lh "$outdir"
echo -e "\n## Done with script soapdenovo.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo
