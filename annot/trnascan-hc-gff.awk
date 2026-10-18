# Pull the high-confidence tRNAs out of a full tRNAscan-SE GFF.
#
# EukHighConfidenceFilter writes only '.out' and '.ss', no GFF, so the subset
# has to be recovered from the full GFF. Its '.out' keeps every prediction and
# marks the surviving ones in the last column, and the GFF ID is the sequence
# name plus '.trna' plus the tRNA number - columns 1 and 2 of the '.out', which
# are space-padded to a fixed width.
#
# Both the feature line and its exon children are kept, so tRNAs with an intron
# come through whole.
#
# Usage: awk -f trnascan-hc-gff.awk hc/PREFIX.out PREFIX.gff > PREFIX.hc.gff3

function attr(s, key,   re, v) {
    re = "(^|;)" key "=[^;]*"
    if (match(s, re)) {
        v = substr(s, RSTART, RLENGTH)
        sub("(^|;)" key "=", "", v)
        return v
    }
    return ""
}

BEGIN { FS = "\t"; OFS = "\t" }

# Pass 1: the high-confidence IDs, from the filtered '.out' (3 header lines)
FNR == NR {
    if (FNR <= 3) next
    if ($NF != "high confidence set") next
    gsub(/ /, "", $1)
    gsub(/ /, "", $2)
    keep[$1 ".trna" $2] = 1
    n_hc++
    next
}

# Pass 2: the GFF, keeping each high-confidence feature and its exon children
/^##gff-version/ { print; next }
/^#/ { next }
{
    id = attr($9, "ID")
    par = attr($9, "Parent")
    sub(/,.*/, "", par)
    if (id in keep || par in keep) print
}

END {
    if (n_hc == 0)
        print "ERROR: no rows marked 'high confidence set' in " ARGV[1] > "/dev/stderr"
}
