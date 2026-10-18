#!/usr/bin/env python3
"""Find reciprocal best hits (RBH) between a query proteome and a donor proteome.

A one-way best hit is not evidence of orthology. In teleosts especially, the
whole-genome duplication at the base of the group (Ts3R) leaves many genes with
a co-orthologous partner, so a query can score highest against a paralog of the
gene it actually corresponds to. Requiring the hit to be best in BOTH
directions removes most of that: the pair has to prefer each other over
everything else in the other proteome.

Inputs are two DIAMOND tabular outputs in the 16-column format that
align/diamond.sh writes:

    1 qseqid  2 sseqid  3 pident   4 length  5 mismatch  6 gapopen  7 qstart
    8 qend    9 sstart  10 send   11 evalue 12 bitscore 13 qlen    14 qcovhsp
   15 slen   16 stitle

  --forward   the query proteome as queries, the donor as subjects
  --reverse   the donor as queries, the query proteome as subjects

Both files are filtered on identity, query coverage and E-value BEFORE the best
hit is chosen, so a filtered-out top hit cannot mask the best surviving one.
Best hit = highest bitscore; ties are broken on E-value and then on subject ID,
so the result does not depend on the order DIAMOND happened to write.

Every query that keeps a hit is reported, with a 'tier' column saying how good
the evidence is:

    RBH             best in both directions - use for gene symbols
    forward_best    best one way only - use for product names, not symbols

Nothing is dropped for being merely one-way: which tiers may donate what is a
decision for the merge step, and it needs to see both.
"""

import argparse
import gzip
import sys
from collections import Counter

# The 16 columns of the DIAMOND output, by position
COL = {name: i for i, name in enumerate(
    "qseqid sseqid pident length mismatch gapopen qstart qend sstart send "
    "evalue bitscore qlen qcovhsp slen stitle".split())}


def smart_open(path):
    """Open a plain or gzipped text file."""
    if str(path).endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path)


def best_hits(path, min_pident, min_qcov, max_evalue):
    """Return {query: (subject, pident, qcov, scov, evalue, bitscore, stitle)}.

    Also returns how many lines were read and how many survived the filters, so
    that a filter set which throws away almost everything is visible in the log
    rather than silently producing an empty table.
    """
    best = {}
    n_lines = n_kept = 0
    with smart_open(path) as fh:
        for line in fh:
            if not line.strip() or line.startswith("#"):
                continue
            f = line.rstrip("\n").split("\t")
            if len(f) < 15:
                sys.exit(f"ERROR: {path} has {len(f)} columns on a line, "
                         f"expected at least 15 - is this the 16-column "
                         f"format that diamond.sh writes?\n  {line[:200]}")
            n_lines += 1
            pident = float(f[COL["pident"]])
            qcov = float(f[COL["qcovhsp"]])
            evalue = float(f[COL["evalue"]])
            if pident < min_pident or qcov < min_qcov or evalue > max_evalue:
                continue
            n_kept += 1

            query = f[COL["qseqid"]]
            subject = f[COL["sseqid"]]
            bitscore = float(f[COL["bitscore"]])
            # DIAMOND's default output has no subject-coverage field, so derive
            # it from the aligned subject range. Single HSP only, hence a floor
            # on the true coverage rather than the exact value.
            slen = int(f[COL["slen"]])
            sstart, send = int(f[COL["sstart"]]), int(f[COL["send"]])
            scov = 100.0 * (abs(send - sstart) + 1) / slen if slen else 0.0
            stitle = f[COL["stitle"]] if len(f) > COL["stitle"] else ""

            # Sort key: highest bitscore, then lowest E-value, then subject ID.
            # The ID tie-break is what makes the choice reproducible.
            key = (-bitscore, evalue, subject)
            if query not in best or key < best[query][0]:
                best[query] = (key, (subject, pident, qcov, scov, evalue,
                                     bitscore, stitle))
    return {q: v[1] for q, v in best.items()}, n_lines, n_kept


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--forward", required=True,
                    help="DIAMOND output, the query proteome as queries")
    ap.add_argument("--reverse", required=True,
                    help="DIAMOND output, the donor proteome as queries")
    ap.add_argument("--out", required=True, help="Output TSV")
    ap.add_argument("--donor", default="donor",
                    help="Label for the donor, written to the 'donor' column")
    ap.add_argument("--min_pident", type=float, default=30.0,
                    help="Minimum percent identity (default: %(default)s)")
    ap.add_argument("--min_qcov", type=float, default=50.0,
                    help="Minimum percent query coverage (default: %(default)s)")
    ap.add_argument("--max_evalue", type=float, default=1e-5,
                    help="Maximum E-value (default: %(default)s)")
    args = ap.parse_args()

    fwd, n_fwd, n_fwd_kept = best_hits(args.forward, args.min_pident,
                                       args.min_qcov, args.max_evalue)
    rev, n_rev, n_rev_kept = best_hits(args.reverse, args.min_pident,
                                       args.min_qcov, args.max_evalue)

    tiers = Counter()
    with open(args.out, "w") as out:
        out.write("\t".join(["query", "subject", "donor", "pident", "qcov",
                             "scov", "evalue", "bitscore", "tier",
                             "stitle"]) + "\n")
        for query in sorted(fwd):
            subject, pident, qcov, scov, evalue, bitscore, stitle = fwd[query]
            # Reciprocal if the donor protein hit best also hits this query best
            reciprocal = rev.get(subject, (None,))[0] == query
            tier = "RBH" if reciprocal else "forward_best"
            tiers[tier] += 1
            out.write("\t".join([
                query, subject, args.donor, f"{pident:.1f}", f"{qcov:.1f}",
                f"{scov:.1f}", f"{evalue:.2g}", f"{bitscore:.1f}", tier,
                stitle]) + "\n")

    n_out = sum(tiers.values())
    print(f"Donor: {args.donor}", file=sys.stderr)
    print(f"  Filters: pident >= {args.min_pident}, qcov >= {args.min_qcov}, "
          f"evalue <= {args.max_evalue}", file=sys.stderr)
    print(f"  Forward hits: {n_fwd} lines, {n_fwd_kept} passed the filters, "
          f"{len(fwd)} queries with a best hit", file=sys.stderr)
    print(f"  Reverse hits: {n_rev} lines, {n_rev_kept} passed the filters, "
          f"{len(rev)} queries with a best hit", file=sys.stderr)
    for tier in ("RBH", "forward_best"):
        pct = 100.0 * tiers[tier] / n_out if n_out else 0.0
        print(f"  {tier:<14} {tiers[tier]:>8} ({pct:.1f}% of reported)",
              file=sys.stderr)
    if n_out == 0:
        sys.exit("ERROR: no hits survived the filters - check the inputs")


if __name__ == "__main__":
    main()
