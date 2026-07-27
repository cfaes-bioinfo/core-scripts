#!/bin/bash
#SBATCH --time=24:00:00
#SBATCH --account=PAS0471
#SBATCH --output=slurm-dirsizes-%j.out

# Parse args
dir=$1
depth=${2:-1}

# Report
echo "# Checking dir size at depth $depth in directory: $dir"
date
echo

# Check dir sizes
du -h -d "$depth" "$dir"

# Report
echo -e "\n# Done."
date

# Examples:
# script=/fs/ess/PAS0471/jelmer/scripts/admin/dirsizes.sh
# for dir in $(find . -maxdepth 1 -type d); do sbatch "$script" "$dir" 1; done
# sbatch "$script" ./osu6702 1
