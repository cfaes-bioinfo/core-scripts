# Retype CDS-bearing 'transcript' features (SO:0000673) as 'mRNA' (SO:0000234).
#
# AGAT passes the input feature type straight through, so a predictor that
# writes the generic term keeps it - Tiberius does - and tools downstream that
# look for 'mRNA' then miss every coding transcript.
#
# The GFF3 has to be passed TWICE: pass 1 records which level-2 IDs have a CDS
# child, pass 2 rewrites. A 'transcript' with no CDS child is left alone.
# Counts go to stderr so stdout stays a clean GFF3.
#
# Usage: awk -f gff3-retype-mrna.awk in.gff3 in.gff3 > out.gff3

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

# Pass 1: which level-2 IDs have a CDS child
FNR == NR {
    if (!/^#/ && $3 == "CDS") {
        p = attr($9, "Parent")
        sub(/,.*/, "", p)
        if (p != "") coding[p] = 1
    }
    next
}

# Pass 2: rewrite, and count what changed
/^#/ { print; next }
{
    if ($3 == "transcript") {
        id = attr($9, "ID")
        if (id in coding) { $3 = "mRNA"; n_retyped++ } else { n_kept++ }
    }
    print
}

END {
    printf "Retyped to mRNA:                          %d\n", n_retyped + 0 > "/dev/stderr"
    printf "Left as transcript (no CDS child):        %d\n", n_kept + 0 > "/dev/stderr"
}
