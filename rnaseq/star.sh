#!/usr/bin/env bash
#SBATCH --account=PAS0471
#SBATCH --time=3:00:00
#SBATCH --cpus-per-task=16
#SBATCH --mem=100G
#SBATCH --mail-type=END,FAIL
#SBATCH --job-name=star
#SBATCH --output=slurm-star-%j.out

# ==============================================================================
#                          CONSTANTS AND DEFAULTS
# ==============================================================================
# Constants - generic
DESCRIPTION="Align RNAseq reads to a STAR genome/transcriptome index with STAR
NOTE: STAR is run with several non-default settings, check this script's code for details."
SCRIPT_VERSION="2026-05-21"
SCRIPT_AUTHOR="Jelmer Poelstra"
REPO_URL=https://github.com/mcic-osu/mcic-scripts
FUNCTION_SCRIPT_URL=https://raw.githubusercontent.com/mcic-osu/mcic-scripts/main/dev/bash_functions.sh
TOOL_BINARY=STAR
TOOL_NAME=STAR
TOOL_DOCS="https://github.com/alexdobin/STAR, https://github.com/alexdobin/STAR/blob/master/doc/STARmanual.pdf"
VERSION_COMMAND="$TOOL_BINARY --version"

# Defaults - generics
env_type=container
conda_path=
container_dir="$HOME/containers"
container_url=oras://community.wave.seqera.io/library/samtools_star:952fa4513a08d418
container_path=

# Constants - tool parameters
# SEE THE STAR COMMAND BELOW FOR SEVERAL HARDCODED PARAMETERS

# Defaults - tool parameters
quantmode_opt="--quantMode TranscriptomeSAM"
max_map=20
sort_bam=samtools
index_bam=false
output_unmapped=false && unmapped_opt=
single_end=false

# ==============================================================================
#                                   FUNCTIONS
# ==============================================================================
script_help() {
    echo -e "
                        $0
    v. $SCRIPT_VERSION by $SCRIPT_AUTHOR, $REPO_URL
            =================================================

DESCRIPTION:
$DESCRIPTION

USAGE / EXAMPLE COMMANDS:
  - Basic usage:
      sbatch $0 -i data/fastq/S01_R1.fastq.gz -o results/star -r refdata/star_index --annot ref.gtf

REQUIRED OPTIONS:
  -r/--index_dir    <dir>   Input STAR reference genome index dir
                            (First create index with 'mcic-scripts/rnaseq/star_index.sh')
  -o/--outdir       <dir>   BAM output dir (will be created if needed)
  --annot           <file>  Ref. annotation file (GFF/GTF - GTF preferred)
                            NOTE: If you don't have or want to use an annotation file,
                            omit this option *and* use the option '--no_transcriptome'.

  To specify the input reads, use one of the following options:
  -i/--R1           <file>  Input gzipped (R1) FASTQ file (R2 name inferred unless '--single_end')
  --fofn            <file>  A File of File Names (FOFN), one line per input file (not for >1 sample)

OTHER KEY OPTIONS:
  --no_transcriptome        Don't use '--quantMode TranscriptomeSAM'      [default: use it for Salmon]
  --output_unmapped         Output unmapped reads as FASTQ                [default: don't output]
  --R2              <file>  Input R2 FASTQ file (for non-standard naming) [default: infer from R1]
  --single_end              FASTQ files are single-end                    [default: $single_end]
  --sort            <str>   'false', 'star', or 'samtools'                [default: $sort_bam]
  --index_bam               Index the output BAM file with samtools       [default: $index_bam]
  --max_map         <int>   Max. nr. of mapping locations for a read      [default: $max_map]
  --intron_min      <int>   Min. intron size                              [default: STAR default]
  --intron_max      <int>   Max. intron size                              [default: STAR default]
  --more_opts       <str>   Quoted string with additional options for $TOOL_NAME

UTILITY OPTIONS:
  --env_type        <str>   Whether to use a Singularity/Apptainer container  [default: $env_type]
                            ('container') or a Conda environment ('conda')
  --container_url   <str>   URL to download a container from                  [default (if any): $container_url]
  --container_dir   <str>   Dir to download a container to                    [default: $container_dir]
  --container_path  <file>  Local container image file ('.sif') to use        [default (if any): $container_path]
  --conda_path      <dir>   Full path to a Conda environment to use           [default: $conda_path]
  -h/--help                 Print this help message
  -v/--version              Print script and $TOOL_NAME versions

TOOL DOCUMENTATION:
  $TOOL_DOCS
"
}

# Function to source the script with Bash functions
source_function_script() {
    # Determine the location of this script, and based on that, the function script
    if [[ "$IS_SLURM" == true ]]; then
        script_path=$(scontrol show job "$SLURM_JOB_ID" | awk '/Command=/ {print $1}' | sed 's/Command=//')
        script_dir=$(dirname "$script_path")
        SCRIPT_NAME=$(basename "$script_path")
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
        SCRIPT_NAME=$(basename "$0")
    fi
    function_script_name="$(basename "$FUNCTION_SCRIPT_URL")"
    function_script_path="$script_dir"/../dev/"$function_script_name"

    # Download the function script if needed, then source it
    if [[ -f "$function_script_path" ]]; then
        source "$function_script_path"
    else
        if [[ ! -f "$function_script_name" ]]; then
            echo "Can't find script with Bash functions ($function_script_name), downloading from GitHub..."
            wget -q "$FUNCTION_SCRIPT_URL" -O "$function_script_name"
        fi
        source "$function_script_name"
    fi
}

# Check if this is a SLURM job, then load the Bash functions
if [[ -z "$SLURM_JOB_ID" ]]; then IS_SLURM=false; else IS_SLURM=true; fi
source_function_script $IS_SLURM

# ==============================================================================
#                          PARSE COMMAND-LINE ARGS
# ==============================================================================
# Initiate variables
version_only=false
R1_in= && R2_in= && fofn=
declare -a infiles
index_dir=
annot=
intron_min=
intron_max=
outdir=
more_opts=
threads=

# Parse command-line options
all_opts="$*"
while [ "$1" != "" ]; do
    case "$1" in
        -o | --outdir )         shift && outdir=$1 ;;
        -i | --R1 )             shift && R1_in=$1 ;;
        --R2 )                  shift && R2_in=$1 ;;
        --fofn )                shift && fofn=$1 ;;
        -r | --index_dir )      shift && index_dir=$1 ;;
        -a | --annot )          shift && annot=$1 ;;
        --max_map )             shift && max_map=$1 ;;
        --intron_min )          shift && intron_min=$1 ;;
        --intron_max )          shift && intron_max=$1 ;;
        --output_unmapped )     output_unmapped=true ;;
        --no_transcriptome )    quantmode_opt= ;;
        --index_bam )           index_bam=true ;;
        --sort )                shift && sort_bam=$1 ;;
        --single_end )          single_end=true ;;
        --more_opts )           shift && more_opts=$1 ;;
        --env_type )            shift && env_type=$1 ;;
        --conda_path )          shift && conda_path=$1 ;;
        --container_dir )       shift && container_dir=$1 ;;
        --container_url )       shift && container_url=$1 ;;
        --container_path )      shift && container_path=$1 ;;
        -h | --help )           script_help; exit 0 ;;
        -v | --version )        version_only=true ;;
        * )                     die "Invalid option $1" "$all_opts" ;;
    esac
    shift
done

# ==============================================================================
#                          INFRASTRUCTURE SETUP
# ==============================================================================
# Strict Bash settings
set -euo pipefail

# Load software
load_env "$env_type" "$conda_path" "$container_dir" "$container_path" "$container_url"
[[ "$version_only" == true ]] && print_version "$VERSION_COMMAND" && exit 0

# Check options provided to the script
[[ -z "$R1_in" && -z "$fofn" ]] && die "No input FASTQ file specified, do so with -i/--R1 or --fofn" "$all_opts"
[[ -z "$index_dir" ]] && die "No index dir specified, do so with -r/--index_dir" "$all_opts"
[[ -z "$outdir" ]] && die "No output dir specified, do so with -o/--outdir" "$all_opts"
[[ -n "$R1_in" && ! -f "$R1_in" ]] && die "Input file $R1_in does not exist"
[[ ! -d "$index_dir" ]] && die "Index dir $index_dir does not exist"
[[ -n "$annot" && ! -f "$annot" ]] && die "Input annotation file (-a) $annot does not exist"
[[ "$sort_bam" != "star" && "$sort_bam" != "samtools" && "$sort_bam" != "false" ]] && die "--sort should be 'false', 'star', or 'samtools', but is $sort_bam"
[[ -n "$quantmode_opt" && -z "$annot" ]] && die "No annotation file provided. Either provide one with '--annot' or use '--no_transcriptome'"

# Input files via FOFN
if [[ -n "$fofn" ]]; then
    mapfile -t infiles <"$fofn"
    R1_in=${infiles[0]}
    [[ ${#infiles[@]} -eq 2 ]] && R2_in=${infiles[1]}
    [[ ${#infiles[@]} -gt 2 ]] && die "FOFN should contain 1 or 2 filenames, not ${#infiles[@]}"
fi

# Determine R2 file, output prefix, etc
if [[ -n "$R1_in" ]]; then
    R1_basename=$(basename "$R1_in" | sed -E 's/.fa?s?t?q.gz//')

    if [[ "$single_end" == false ]]; then
        R1_suffix=$(echo "$R1_in" | sed -E 's/.*(_R?1).*fa?s?t?q.gz/\1/')
        sampleID=${R1_basename/"$R1_suffix"/}

        if [[ -z "$R2_in" ]]; then
            R2_suffix=${R1_suffix/1/2}
            R2_in=${R1_in/$R1_suffix/$R2_suffix}
        fi

        [[ ! -f "$R1_in" ]] && die "Input file R1 $R1_in does not exist"
        [[ ! -f "$R2_in" ]] && die "Input file R2 $R2_in does not exist"
        [[ "$R1_in" == "$R2_in" ]] && die "Input file R1 is the same as R2"
    else
        sampleID="$R1_basename"
    fi
fi

# Define outputs based on script parameters
LOG_DIR="$outdir"/logs
mkdir -p "$LOG_DIR"
outfile_prefix="$outdir/$sampleID"_
starlog_dir="$outdir"/star_logs
final_bam="$outdir"/bam/"$sampleID".bam
map2trans_bam="$outdir"/bam/"$sampleID"_map2trans.bam
mkdir -p "$outdir"/bam "$starlog_dir"

# Build annotation argument
annot_opt=
annot_tags=
if [[ -n "$annot" ]]; then
    annot_opt="--sjdbGTFfile $annot"
    if [[ "$annot" =~ .*\.gff3? ]]; then
        annot_tags="--sjdbGTFtagExonParentTranscript Parent"
    fi
fi

# Sorted output or not
if [[ "$sort_bam" == "star" ]]; then
    output_opt="--outSAMtype BAM SortedByCoordinate --outBAMsortingBinsN 100"
else
    output_opt="--outSAMtype BAM Unsorted"
fi

# Output unmapped reads in a FASTQ file
if [[ "$output_unmapped" == true ]]; then
    unmapped_opt="--outReadsUnmapped Fastx"
    unmapped_dir="$outdir"/unmapped
    mkdir -p "$unmapped_dir"
fi

# Other options
intron_min_opt=
intron_max_opt=
[[ -n "$intron_min" ]] && intron_min_opt="--alignIntronMin $intron_min"
[[ -n "$intron_max" ]] && intron_max_opt="--alignIntronMax $intron_max"

# ==============================================================================
#                         REPORT PARSED OPTIONS
# ==============================================================================
log_time "Starting script $SCRIPT_NAME, version $SCRIPT_VERSION"
echo "=========================================================================="
echo "All options passed to this script:            $all_opts"
echo "Working directory:                            $PWD"
echo
echo "Output BAM dir:                               $outdir"
echo "Input R1 FASTQ file:                          $R1_in"
[[ -n "$R2_in" ]] && echo "Input R2 FASTQ file:                          $R2_in"
echo "Are FASTQ reads single-end?                   $single_end"
echo "Input STAR genome index dir:                  $index_dir"
[[ -n "$annot" ]] && echo "Input annotation file:                        $annot"
echo "Output unmapped reads as FASTQ:               $output_unmapped"
echo "Max nr of alignments for a read:              $max_map"
[[ -n "$intron_min" ]] && echo "Minimum intron size:                          $intron_min"
[[ -n "$intron_max" ]] && echo "Maximum intron size:                          $intron_max"
echo "Sort the output BAM file:                     $sort_bam"
echo "Index the output BAM file:                    $index_bam"
echo "Sample ID (as inferred by the script):        $sampleID"
[[ -n $more_opts ]] && echo "Additional options for $TOOL_NAME:            $more_opts"
log_time "Listing the input file(s):"
ls -lhd "$index_dir"
ls -lh "$R1_in"
[[ -n "$R2_in" ]] && ls -lh "$R2_in"
[[ -n "$annot" ]] && ls -lh "$annot"
set_threads "$IS_SLURM"
[[ "$IS_SLURM" == true ]] && slurm_resources

# ==============================================================================
#                               RUN
# ==============================================================================
log_time "Running $TOOL_NAME..."
runstats $TOOL_BINARY \
    --genomeDir "$index_dir" \
    --readFilesIn "$R1_in" "$R2_in" \
    --outFilterMultimapNmax $max_map \
    --outFileNamePrefix "$outfile_prefix" \
    --runThreadN "$threads" \
    --outSAMattrRGline ID:"$sampleID" SM:"$sampleID" \
    --readFilesCommand zcat \
    --twopassMode Basic \
    --outSAMstrandField intronMotif \
    --outSAMattributes NH HI AS NM MD \
    --runRNGseed 0 \
    --alignSJDBoverhangMin 1 \
    --quantTranscriptomeSAMoutput "BanSingleEnd" \
    $intron_min_opt \
    $intron_max_opt \
    $annot_opt \
    $annot_tags \
    $quantmode_opt \
    $unmapped_opt \
    $output_opt \
    $more_opts

# Sort BAM with samtools sort
if [[ "$sort_bam" == "samtools" ]]; then
    log_time "Sorting the main BAM file with samtools sort..."
    bam_unsorted="$outfile_prefix"Aligned.out.bam
    bam_sorted="$outfile_prefix"Aligned.sortedByCoord.out.bam
    runstats samtools sort -o "$bam_sorted" "$bam_unsorted"
    [[ -s "$bam_sorted" ]] && rm -v "$bam_unsorted"
fi

# ==============================================================================
#                           ORGANIZE THE OUTPUT
# ==============================================================================
# Move the output BAM file(s)
log_time "Moving the output BAM file(s)..."
if [[ "$sort_bam" != "false" ]]; then
    mv -v "$outfile_prefix"Aligned.sortedByCoord.out.bam "$final_bam"
else
    mv -v "$outfile_prefix"Aligned.out.bam "$final_bam"
fi
if [[ -n "$quantmode_opt" ]]; then
    mv -v "$outfile_prefix"Aligned.toTranscriptome.out.bam "$map2trans_bam"
fi

# Index the output BAM file(s)
if [[ "$index_bam" == true ]]; then
    log_time "Indexing the output BAM file(s)..."
    runstats samtools index "$final_bam"
    [[ -n "$quantmode_opt" ]] && runstats samtools index "$map2trans_bam"
fi

# Organize unmapped FASTQ files
if [[ "$output_unmapped" == true ]]; then
    log_time "Moving, renaming and zipping unmapped FASTQ files..."
    for oldpath in "$outfile_prefix"*Unmapped.out.mate*; do
        oldname=$(basename "$oldpath")
        newname=$(echo "$oldname" | sed -E s'/_Unmapped.out.mate([12])/_R\1.fastq.gz/')
        newpath="$unmapped_dir"/"$newname"

        log_time "Fixing FASTQ format for $oldpath and outputting $newpath..."
        [[ "$newpath" = *R1.fastq.gz ]] && sed -E 's/(^@.*) 0:N: (.*)/\1 1:N: \2/' "$oldpath" | gzip -f > "$newpath"
        [[ "$newpath" = *R2.fastq.gz ]] && sed -E 's/(^@.*) 1:N: (.*)/\1 2:N: \2/' "$oldpath" | gzip -f > "$newpath"
        rm "$oldpath"
    done
fi

# Move STAR log files
log_time "Moving the STAR log files..."
mv -v "$outfile_prefix"Log*out "$starlog_dir"

# ==============================================================================
#                               WRAP-UP
# ==============================================================================
# Show alignment % lines from STAR log
log_time "Showing alignment rate from STAR log..."
grep "Uniquely mapped reads %" "$starlog_dir"/"$sampleID"_Log.final.out
grep "% of reads mapped to multiple loci" "$starlog_dir"/"$sampleID"_Log.final.out

log_time "Listing the output BAM file(s):"
ls -lh "$final_bam"
[[ -n "$quantmode_opt" ]] && ls -lh "$map2trans_bam"
if [[ "$output_unmapped" == true ]]; then
    log_time "Listing the FASTQ files with unmapped reads:"
    ls -lh "$unmapped_dir/$sampleID"*fastq.gz
fi

final_reporting "$LOG_DIR"
