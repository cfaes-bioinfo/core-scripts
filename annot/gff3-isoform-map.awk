# Build an OMArk --isoform_file from a GFF3: one line per gene, the IDs of its
# proteins separated by ';', in the order the genes first appear.
#
# The GFF3 has to be passed TWICE, because a CDS line only points at its
# transcript: pass 1 maps transcript ID -> gene ID from the mRNA/transcript
# features, pass 2 walks the CDS lines.
#
# The protein ID is the CDS 'protein_id' attribute where the file uses that
# (NCBI style), and the transcript ID otherwise, which is what gffread writes
# into its protein FASTA headers. In a file that uses protein_id, a CDS without
# one is skipped rather than given a made-up ID: in RefSeq GFF3s
# those are V_gene_segment loci, which have CDS features but no protein in the
# FASTA. Only CDS-bearing transcripts are listed, so non-coding genes drop out.
#
# Usage: awk -f gff3-isoform-map.awk in.gff3 in.gff3 > isoforms.txt

function attr(s, key,   re, v) {
    re = "(^|;)" key "=[^;]*"
    if (match(s, re)) {
        v = substr(s, RSTART, RLENGTH)
        sub("(^|;)" key "=", "", v)
        return v
    }
    return ""
}

BEGIN { FS = "\t" }

/^#/ { next }
NF < 9 { next }
{ gsub(/\r$/, "", $9) }

# Pass 1: transcript ID -> gene ID, and whether the file uses protein_id at all
FNR == NR {
    if ($3 == "mRNA" || $3 == "transcript") {
        id = attr($9, "ID")
        par = attr($9, "Parent")
        sub(/,.*/, "", par)
        if (id != "" && par != "") tx2gene[id] = par
    } else if ($3 == "CDS" && attr($9, "protein_id") != "") {
        uses_protein_id = 1
    }
    next
}

# Pass 2: one entry per (gene, protein), first-seen order kept
$3 == "CDS" {
    tx = attr($9, "Parent")
    sub(/,.*/, "", tx)
    if (tx == "") next
    prot = attr($9, "protein_id")
    if (prot == "") {
        if (uses_protein_id) next
        prot = tx
    }
    gene = (tx in tx2gene) ? tx2gene[tx] : tx

    if ((gene SUBSEP prot) in seen) next
    seen[gene SUBSEP prot] = 1
    if (gene in prots) {
        prots[gene] = prots[gene] ";" prot
    } else {
        order[++n_genes] = gene
        prots[gene] = prot
    }
}

END {
    for (i = 1; i <= n_genes; i++) print prots[order[i]]
}
