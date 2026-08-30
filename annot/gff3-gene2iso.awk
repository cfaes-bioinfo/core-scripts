# Emit a 'gene<TAB>protein' table from a GFF3, for longest_tx.sh.
#
# The GFF3 has to be passed TWICE, because a CDS line only points at its
# transcript, not the gene ID.
#
# The protein ID comes from the CDS 'protein_id' attribute when there is one
# (NCBI style), and otherwise from the transcript ID, which is what gffread
# writes into its protein FASTA headers. IDs that are absent from the proteome
# FASTA fall out later, when longest_tx.sh joins this table against the
# isoform-length table.
#
# Usage: awk -f gff3-gene2iso.awk in.gff3 in.gff3

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

/^#/ { next }
{ gsub(/\r$/, "", $9) }

# Pass 1: transcript ID -> gene ID
FNR == NR {
    if ($3 == "mRNA" || $3 == "transcript") {
        id = attr($9, "ID")
        par = attr($9, "Parent")
        sub(/,.*/, "", par)
        if (id != "" && par != "") tx2gene[id] = par
    }
    next
}

# Pass 2: one row per CDS-bearing transcript
$3 == "CDS" {
    tx = attr($9, "Parent")
    sub(/,.*/, "", tx)
    if (tx == "") next
    prot = attr($9, "protein_id")
    if (prot == "") prot = tx
    gene = (tx in tx2gene) ? tx2gene[tx] : tx
    print gene, prot
}
