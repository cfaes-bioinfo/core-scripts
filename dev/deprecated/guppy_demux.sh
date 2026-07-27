#!/bin/bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=8
#SBATCH --output=slurm-guppy_demux-%j.out
set -ueo pipefail

# SETUP ------------------------------------------------------------------------
# Load software (https://community.nanoporetech.com/downloads)
GUPPY_DIR=/fs/ess/PAS0471/jelmer/software/guppy-6.5.7/ont-guppy
DEMUX_BIN="$GUPPY_DIR"/bin/guppy_barcoder
CONFIG_FILE="$GUPPY_DIR"/data/barcoding/configuration.cfg

# Command-line args
indir=$1
outdir=$2
barcode_kit=$3

# Input checks
[[ "$#" != 3 ]] && echo "# ERROR: Please provide 3 arguments; you provided $#" && exit 1
[[ ! -d "$indir" ]] && echo "# ERROR: Input dir does not exist" && exit 1

# Create the output directory if it doesn't already exist
mkdir -p "$outdir"

# Report
echo "# Starting script guppy_demux.sh..."
date
echo
echo "# Input dir with FASTQ/FAST5/POD5 files:      $indir"
echo "# Output dir:                                 $outdir"
echo "# Barcode kit name:                           $barcode_kit"
echo -e "--------------------\n"

# RUN GUPPY -------------------------------------------------------------------
$DEMUX_BIN \
    -i "$indir" \
    -s "$outdir" \
    --barcode_kits "$barcode_kit" \
    --fastq_out \
    --compress_fastq \
    --records_per_fastq 0 \
    --config "$CONFIG_FILE" \
    -t "$SLURM_CPUS_PER_TASK"

# WRAP UP ----------------------------------------------------------------------
echo -e "\n# Listing files in output dir:"
ls -lh "$outdir"

echo -e "\n# Done with script guppy_demux.sh"
date
