# Emit BED intervals for the repeat classes named in -v classes.
#
# Matching is on the part of GFF column 3 before any '/', so 'LINE' picks up
# 'LINE/L2', 'LINE/Rex-Babar' and so on, and a class with no subdivision
# ('Unknown', 'Retroposon') matches itself. Output is unsorted and unmerged -
# pipe it through 'sort -k1,1 -k2,2n | bedtools merge'.
#
# Usage: awk -v classes=DNA,LINE,LTR,SINE,RC,PLE,Retroposon \
#            -f repeat-gff-to-bed.awk repeats.gff

BEGIN {
    FS = "\t"; OFS = "\t"
    n = split(classes, a, ",")
    for (i = 1; i <= n; i++) keep[a[i]] = 1
}

/^#/ { next }

{
    split($3, c, "/")
    if (c[1] in keep) print $1, $4 - 1, $5
}
