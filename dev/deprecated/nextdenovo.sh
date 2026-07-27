#!/bin/bash

#SBATCH --account=PAS0471
#SBATCH --time=48:00:00
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=nextdenovo
#SBATCH --output=slurm-nextdenovo-%j.out

# FUNCTIONS --------------------------------------------------------------------
## Help function
Print_help() {
    echo
    echo "================================================================================="
    echo "         $0: Run Nextdenovo to assemble a genome"
    echo "================================================================================="
    echo "USAGE:"
    echo "  sbatch $0 -f <fofn> -o <outdir> -s <genome-size> [...]"
    echo "  bash $0 -h"
    echo
    echo "REQUIRED OPTIONS:"
    echo "    -i FILE           File of file names (fofn) of input FASTQ files"
    echo "    -o DIR            Output directory"
    echo "    -s STRING         Estimated genome size, e.g. '1g' or '300m'"
    echo
    echo "OTHER KEY OPTIONS:"
    echo "    -l STRING         Minimum read length, e.g. 5000 bp => '5k'              [default: '1k']"
    echo "    -w DIR            Work dir - initial output dir before files are copied"
    echo "                      [default: '/fs/scratch/PAS0471/\$USER/nextdenovo/\$(basename \$outdir)']"
    echo "    -a STRING         Other argument(s) to pass to Nextdenovo, all as a single quoted string"
    echo
    echo "UTILITY OPTIONS"
    echo "    -h                Print this help message and exit"
    echo "    -v                Print the version of nextDenovo and exit"
    echo
    echo "EXAMPLE COMMAND:"
    echo "  sbatch $0 -f fastqs.fofn -o results/nextdenovo -s 1g"
    echo
    echo "SOFTWARE DOCUMENTATION:"
    echo "- https://nextdenovo.readthedocs.io/en/latest/OPTION.html"
    echo
}

## Load software
Load_software() {
    module load python
    source activate /fs/ess/PAS0471/jelmer/conda/nextdenovo-env
    MCIC_SCRIPTS_REPO=https://github.com/mcic-osu/mcic-scripts.git
    TEMPLATE_CONFIG=mcic-scripts/assembly/nextdenovo.cfg
}

## Print version
Print_version() {
    Load_software
    nextDenovo --version
}

## Exit upon error with a message
Die() {
    printf "\n$0: ERROR: %s\n" "$1" >&2
    echo -e "Exiting\n" >&2
    exit 1
}


# PARSE OPTIONS ----------------------------------------------------------------
## Option defaults
min_readlen="1k"
WORKDIR_BASE="/fs/scratch/PAS0471/$USER/nextdenovo/"

workdir=""
fofn=""
outdir=""
genome_size=""
more_args=""

## Parse command-line options
while getopts ':i:o:s:l:w:a:vh' flag; do
    case "${flag}" in
        i) fofn="$OPTARG" ;;
        o) outdir="$OPTARG" ;;
        w) workdir="$OPTARG" ;;
        s) genome_size="$OPTARG" ;;
        l) min_readlen="$OPTARG" ;;
        a) more_args="$OPTARG" ;;
        v) Print_version; exit 0 ;;
        h) Print_help; exit 0 ;;
        \?) Print_help; Die "Invalid option $OPTARG" ;;
        :) Print_help; Die "Option -$OPTARG requires an argument" ;;
    esac
done


# SETUP ------------------------------------------------------------------------
## Load software
Load_software

## Bash script settings
set -euo pipefail

## Check input
[[ $fofn = "" ]] && Die "Please specify a file of file names (fofn) with -i"
[[ $outdir = "" ]] && Die "Please specify an output dir -o"
[[ $genome_size = "" ]] && Die "Please specify an estimated genome size with -s"
[[ ! -f $fofn ]] && Die "File $fofn does not exist!"

## Make path to FOFN absolute, if needed
[[ ! "$fofn" =~ ^/ ]] && fofn="$PWD"/"$fofn"

## Workdir
[[ "$workdir" = "" ]] && workdir="$WORKDIR_BASE"/$(basename "$outdir")

## Report
echo
echo "=========================================================================="
echo "                     STARTING SCRIPT NEXTDENOVO.SH"
date
echo "=========================================================================="
echo "File of file names:                       $fofn"
echo "Output dir:                               $outdir"
echo "Work dir:                                 $workdir"
echo "Estimated genome size:                    $genome_size"
echo "Minimum read length:                      $min_readlen"
[[ $more_args != "" ]] && echo "Other arguments to pass to NextDenovo:    $more_args"
echo
echo "Printing the contents of the fofn file:"
cat -n "$fofn"
echo "=========================================================================="
echo

# MAIN -------------------------------------------------------------------------
## Make the output dir
mkdir -p "$outdir"/logs

## Create config file
echo "## Creating the config file for Nextdenovo..."
config_file="$PWD"/"$outdir"/nextdenovo.cfg
[[ ! -f "$TEMPLATE_CONFIG" ]] && git clone "$MCIC_SCRIPTS_REPO"
cp -v "$TEMPLATE_CONFIG" "$config_file"

sed -i  -e "s@/absolute/path/to/file.fofn@$fofn@" \
        -e "s@path/to/workdir@$workdir@" \
        -e "s/genome_size = .*/genome_size = $genome_size/" \
        -e "s/read_cutoff = .*/read_cutoff = $min_readlen/" \
        "$config_file"

## Show config file contents
echo -e "\n## Printing the contents of the config file:"
ls -lh "$config_file"
cat -n "$config_file"
echo -e "--------------------\n"

## Move to outdir since nextDenovo will put some files in the cwd
cd "$outdir" || exit

## Run nextDenovo
set -o xtrace
nextDenovo "$config_file" $more_args
set +o xtrace

## Copy the output
cp -r "$workdir" "$outdir"


# WRAP UP ----------------------------------------------------------------------
echo -e "\n-------------------------------"
echo "## Version used:"
Print_version | tee "$outdir"/logs/version.txt
echo -e "\n## Listing files in the output dir:"
ls -lhd "$PWD"/"$outdir"/*
echo -e "\n## Done with script"
date
echo
sacct -j "$SLURM_JOB_ID" -o JobID,AllocTRES%50,Elapsed,CPUTime,TresUsageInTot,MaxRSS
echo

#? Info
## Can run the seq_stat utility to determine 'seed_depth',
## though this does not seem necessary as NextDenovo does this anyway
# seq_stat "$fofn" -g "$genome_size" -f "$min_readlen" -o "$outdir"/seq_stat.txt