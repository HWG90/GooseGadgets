"""Move one original C++ source to 26251122 literals by matching masked lines against the ported source.

Same method as unport.py: a line of the original that carries a 0x literal or a hex fingerprint is
rewritten with the literals of the identical (masked) line in the ported file; a line with no single
match is listed as unresolved for the hand map in build_dll.py.

Usage: python3 -I unport_cpp.py ORIGINAL.cpp PORTED.cpp OUT.cpp REPORT.json
"""
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from unport import literals, mask, substitute, GLOBAL


def main():
    original, ported, out, report_path = (Path(a) for a in sys.argv[1:5])
    index = {}
    plines = ported.read_text().splitlines()
    for lineno, pline in enumerate(plines, 1):
        lits = literals(pline)
        if lits: index.setdefault(mask(pline), []).append((lineno, lits))
    lines = original.read_text().splitlines()
    report = {'changed': 0, 'unresolved': []}
    for i, line in enumerate(lines):
        lits = literals(line)
        if not lits: continue
        same = {tuple(h[1]) for h in index.get(mask(line), []) if len(h[1]) == len(lits)}
        if len(same) != 1 and all(l in GLOBAL for l in lits): same = {tuple(GLOBAL[l] for l in lits)}
        if len(same) != 1:
            report['unresolved'].append({'line': i + 1, 'text': line.strip()[:200], 'literals': lits[:12]})
            continue
        new = next(iter(same))
        if list(new) != lits: lines[i] = substitute(line, new); report['changed'] += 1
    out.write_text('\n'.join(lines) + '\n')
    report_path.write_text(json.dumps(report, indent=1) + '\n')
    print('changed', report['changed'], 'unresolved', len(report['unresolved']))
    for u in report['unresolved']: print('  %d: %s' % (u['line'], u['text'][:150]))


if __name__ == '__main__':
    main()
