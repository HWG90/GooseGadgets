"""One verified `ret` per game.dll page that Bridge reads or calls.

Build 26251122 keeps a code page encrypted (PAGE_NOACCESS) until the game first executes it. Calling a
`ret` on such a page through FFI makes the game's own handler decrypt it (checked live 2026-10-30 03:04:
page 0x9c0000 went from protection 1 to 0x20 and read back as the capture). Each site is an instruction
boundary reached from a real call target by following the code (fall-through, direct jumps and both sides
of conditional jumps) in the decrypted capture, so the byte at the site is a `ret` in the game's own code.

Usage: python3 -I warmup_sites.py CAPTURE WITNESSES.json [...] [--rva 0x...]* > code_warmup_sites.lua
"""
import json, struct, sys
sys.path.insert(0, '/home/goose/Documents/Codex/2026-10-22/a-2/work/ffi-comparison/python-deps')
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

PAGE = 4096


def main():
    args = sys.argv[1:]
    cap = open(args[0], 'rb').read()
    pe = struct.unpack_from('<I', cap, 0x3c)[0]
    stamp = struct.unpack_from('<I', cap, pe + 8)[0]
    nsec = struct.unpack_from('<H', cap, pe + 6)[0]; opt = struct.unpack_from('<H', cap, pe + 20)[0]
    text = None
    for i in range(nsec):
        o = pe + 24 + opt + i * 40
        if cap[o:o + 8].rstrip(b'\0') == b'.text':
            vs, va = struct.unpack_from('<II', cap, o + 8); text = (va, va + vs)
    lo, hi = text
    rvas = set()
    i = 1
    while i < len(args):
        if args[i] == '--rva': rvas.add(int(args[i + 1], 16) // PAGE * PAGE); i += 2; continue
        data = json.load(open(args[i])); rows = data if isinstance(data, list) else list(data.values())
        for r in rows:
            if isinstance(r, dict) and str(r.get('module', 'game')) == 'game':
                rva = r.get('new_rva') or r.get('rva')
                if isinstance(rva, str): rva = int(rva, 16)
                if rva is None: continue
                b = r.get('bytes', 16)
                n = b if isinstance(b, int) else len(b) // 2 or 16
                for p in range(rva // PAGE * PAGE, (rva + n + PAGE - 1) // PAGE * PAGE, PAGE): rvas.add(p)
        i += 1
    pages = sorted({p for p in rvas if lo <= p < hi})
    # Verified instruction boundaries: targets of direct calls and jumps anywhere in .text.
    bounds = {p: set() for p in pages}
    for p in list(pages): bounds.setdefault(p - PAGE, set()); bounds.setdefault(p + PAGE, set())
    for op in (b'\xe8', b'\xe9'):
        j = lo
        while True:
            j = cap.find(op, j, hi)
            if j == -1: break
            t = j + 5 + struct.unpack_from('<i', cap, j + 1)[0]
            p = t // PAGE * PAGE
            if p in bounds: bounds[p].add(t)
            j += 1
    j = lo
    while True:
        j = cap.find(b'\x0f', j, hi)
        if j == -1: break
        if 0x80 <= cap[j + 1] <= 0x8f:
            t = j + 6 + struct.unpack_from('<i', cap, j + 2)[0]
            p = t // PAGE * PAGE
            if p in bounds: bounds[p].add(t)
        j += 1
    # Short jumps (jcc rel8, jmp rel8) that land on a wanted page, scanned only near those pages.
    for page in list(bounds):
        for j in range(max(lo, page - 256), min(hi, page + PAGE + 256)):
            b = cap[j]
            if 0x70 <= b <= 0x7f or b == 0xeb:
                t = j + 2 + struct.unpack_from('<b', cap, j + 1)[0]
                if page <= t < page + PAGE and lo <= page < hi: bounds[page].add(t)
    md = Cs(CS_ARCH_X86, CS_MODE_64)

    def ret_on(page, entry, limit=20000):
        work, seen = [entry], set()
        while work and len(seen) < limit:
            at = work.pop()
            if at in seen or not (lo <= at < hi): continue
            seen.add(at)
            ins = next(md.disasm(cap[at:at + 16], at), None)
            if ins is None: continue
            if ins.mnemonic == 'ret':
                # A plain one-byte ret only: `ret imm16` would also pop imm16 bytes of stack.
                if ins.size == 1 and cap[ins.address] == 0xC3 and ins.address // PAGE * PAGE == page: return ins.address
                continue
            if ins.mnemonic in ('int3', 'ud2', 'hlt'): continue
            if ins.mnemonic == 'jmp':
                if ins.op_str.startswith('0x'): work.append(int(ins.op_str, 16))
                continue
            if ins.mnemonic.startswith('j') and ins.op_str.startswith('0x'): work.append(int(ins.op_str, 16))
            work.append(ins.address + ins.size)
        return None

    sites, missing = [], []
    for page in pages:
        if not any(cap[page:page + PAGE]): missing.append((page, 'absent from capture')); continue
        found = None
        # Boundaries on the page itself first, then flow that enters it from the neighbouring pages.
        seeds = sorted(bounds[page]) + sorted(bounds.get(page - PAGE, ())) + sorted(bounds.get(page + PAGE, ()))
        for b in seeds:
            found = ret_on(page, b)
            if found: break
        if found is None: missing.append((page, 'no ret reached')); continue
        sites.append((page, found, cap[found:found + 8].hex()))
    print('-- Generated by native-work/bridge-original/warmup_sites.py from the 26251122 capture.')
    print('-- {page, ret, bytes}: one game.dll page Bridge needs, a ret instruction on it, and the 8 bytes there.')
    print('return {stamp=0x%08X,sites={' % stamp)
    for page, ret, hx in sites: print(' {0x%x,0x%x,"%s"},' % (page, ret, hx))
    print('}}')
    sys.stderr.write('pages %d sites %d missing %s\n' % (len(pages), len(sites), [(hex(p), w) for p, w in missing]))


if __name__ == '__main__':
    main()
