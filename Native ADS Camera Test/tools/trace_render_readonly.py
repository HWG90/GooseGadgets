"""Read bounded engine excerpts through the existing diagnostic bridge.

No setters, pose updates, callbacks, hooks, or input operations are used.
Output is ordinary Capstone disassembly, not REA provider evidence.
"""
import argparse
import json
import re
import sys
from pathlib import Path
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

sys.path.insert(0, r'C:\Users\david\AppData\Local\LinksLinkToMemory\tools')
import llm

parser = argparse.ArgumentParser()
parser.add_argument('rva', nargs='+', type=lambda x: int(x, 16))
parser.add_argument('--size', type=int, default=768)
args = parser.parse_args()
assert 0 < args.size <= 1024 and len(args.rva) <= 16
prefix = '''local a=assert(rawget(_G,"NativeADSCameraTest"));local function up(f,k)for i=1,80 do local n,v=debug.getupvalue(f,i);if not n then break end;if n==k then return v end end end;local b=assert(up(a.start_fird,"backend"));local exe=b:_alignment_executable();local out={};'''
src = prefix + 'for _,r in ipairs({' + ','.join(map(str,args.rva)) + '})do local bytes=b:_read(exe+r,'+str(args.size)+');out[#out+1]=string.format("%x",r).." "..(bytes:gsub(".",function(c)return string.format("%02x",c:byte())end))end;return table.concat(out,"\\n")'
result = str(llm.run(['eval local f=assert(loadstring('+json.dumps(src)+'));setfenv(f,getfenv(1));return f()'], timeout=10))
root = Path(__file__).resolve().parents[1] / 'dist/research/fird-person'
tag = '-'.join(f'{r:x}' for r in args.rva)
(root / (tag+'-raw.txt')).write_text(result)
match = re.search(r'= bytes ([0-9a-fA-F]+)',result)
decoded = bytes.fromhex(match[1]).decode() if match else result.replace('\\n','\n')
md=Cs(CS_ARCH_X86,CS_MODE_64)
lines=[]
for r,code in re.findall(r'([0-9a-f]+) ([0-9a-f]{100,})', decoded):
    lines.append('\nRVA '+r)
    lines.extend(f'{i.address:08x} {i.mnemonic:8} {i.op_str}' for i in md.disasm(bytes.fromhex(code),int(r,16)))
text='\n'.join(lines)
(root/(tag+'-disasm.txt')).write_text(text)
print(text if lines else result)
