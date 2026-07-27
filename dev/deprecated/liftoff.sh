#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=24:00:00
#SBATCH --cpus-per-task=12
#SBATCH --mem=50G
#SBATCH --job-name=liftoff
#SBATCH --output=slurm-liftoff-%j.out


# PARSE ARGUMENTS --------------------------------------------------------------
## Help function
Help() {
  echo
  echo "$0: Run Liftoff to liftover annotations from one genome assembly to another."
  echo
  echo "Syntax: $0 -f <ref-FASTA> -F <target-FASTA> -g <ref-GFF> -o <output-dir>..."
  echo
  echo "Required options:"
  echo      "-f STRING         Reference/source FASTA file"
  echo      "-F STRING         Target FASTA file"
  echo      "-g STRING         Reference/source GFF file"
  echo      "-o STRING         Output directory (for target GFF file, which will be created by the program)"
  echo
  echo "Other options:"
  echo      "-a STRING         Other argument(s) to pass to Braker2"
  echo      "-h                Print this help message"
  echo
  echo "Example:               $0 -f ref/v1.fa -F ref/v2.fa -g ref/v1.gff -o results/liftoff"
  echo "To submit the OSC queue, preface with 'sbatch': sbatch $0 ..."
  echo
  echo "Liftoff documentation: https://github.com/agshumate/Liftoff"
  echo "Liftoff paper: https://academic.oup.com/bioinformatics/advance-article-abstract/doi/10.1093/bioinformatics/btaa1016/6035128"
  echo
}

## Option defaults
target_fa=""
ref_fa=""
ref_gff=""
outdir=""
more_args=""

## Parse command-line options
while getopts ':f:F:g:o:a:h' flag; do
  case "${flag}" in
    f) ref_fa="$OPTARG" ;;
    F) target_fa="$OPTARG" ;;
    g) ref_gff="$OPTARG" ;;
    o) outdir="$OPTARG" ;;
    a) more_args="$OPTARG" ;;
    h) Help && exit 0 ;;
    \?) echo -e "\n## $0: ERROR: Invalid option -$OPTARG\n\n" >&2 && exit 1 ;;
    :) echo -e "\n## $0: ERROR: Option -$OPTARG requires an argument\n\n" >&2 && exit 1 ;;
  esac
done

## Check input
[[ "$ref_fa" = "" ]] && echo "## ERROR: Please specify a reference FASTA file with -f" >&2 && exit 1
[[ "$target_fa" = "" ]] && echo "## ERROR: Please specify a target FASTA file with -F" >&2 && exit 1
[[ "$ref_gff" = "" ]] && echo "## ERROR: Please specify a reference GFF file with -g" >&2 && exit 1
[[ "$outdir" = "" ]] && echo "## ERROR: Please specify an output directory with -o" >&2 && exit 1
[[ ! -f "$ref_fa" ]] && echo "## ERROR: Reference FASTA file (-f) $ref_fa does not exist" >&2 && exit 1
[[ ! -f "$target_fa" ]] && echo "## ERROR: Target FASTA file (-F) $target_fa does not exist" >&2 && exit 1
[[ ! -f "$ref_gff" ]] && echo "## ERROR: Reference GFF file (-g) $ref_gff does not exist" >&2 && exit 1


# SETUP ------------------------------------------------------------------------
## Load software
module load python/3.6-conda5.2
source activate /fs/ess/PAS0471/jelmer/conda/liftoff-1.6.3

## Bash strict mode
set -euo pipefail

## Make output dir
mkdir -p "$outdir"

## Assign name to output GFF
target_gff="$outdir"/$(basename "$target_fa" | sed -E 's/.fn?as?t?a?//')_v1-liftover.gff

## Report
echo
echo "## Starting script liftoff.sh"
date
echo
echo "## Reference FASTA:                       $ref_fa"
echo "## Target FASTA:                          $target_fa"
echo "## Reference GFF:                         $ref_gff"
echo "## Output dir:                            $outdir"
[[ "$more_args" != "" ]] && echo "## Other arguments to pass to liftoff:    $more_args"
echo
echo "## Target GFF:                            $target_gff"
echo -e "--------------------\n"


# RUN LIFTOFF ------------------------------------------------------------------
echo "## Now running Liftoff..."

liftoff \
    -g "$ref_gff" \
    -u "$outdir"/unmapped_features.txt \
    -dir "$TMPDIR" \
    -o "$target_gff" $more_args \
    "$target_fa" "$ref_fa"


# WRAP-UP ----------------------------------------------------------------------
echo -e "\n-------------------------------"
echo "## Listing files in the output dir:"
ls -lh "$outdir"/*
echo -e "\n## Done with script liftoff.sh"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo
