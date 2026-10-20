"""Generate bounded guards from the authenticated local capture; never accesses a process."""
from pathlib import Path
import argparse
import hashlib
import struct
from capstone import Cs, CS_ARCH_X86, CS_MODE_64, CS_OP_MEM, CS_AC_WRITE
from capstone.x86 import X86_REG_RSP, X86_REG_RBP

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('image',type=Path)
args=parser.parse_args()
data=args.image.read_bytes()
assert hashlib.sha256(data).hexdigest()=='642b0aac0b4f577054993a965054827455ef143ced9895b2dfd09d1ecd433a37'
pe=struct.unpack_from('<I',data,60)[0]+24
assert struct.unpack_from('<I',data,pe-16)[0]==0x6AB3B43F
table,size=struct.unpack_from('<II',data,pe+136)
rows=[struct.unpack_from('<III',data,at) for at in range(table,table+size,12)]
def canonical(row):
    a,z,u=row
    if data[u]>>3&4:
        return canonical(struct.unpack_from('<III',data,u+4+((data[u+2]+1)&~1)*2))
    return a
groups={}
for row in rows:groups.setdefault(canonical(row),[]).append(row)
decoder=Cs(CS_ARCH_X86,CS_MODE_64);decoder.detail=True
sites=[]
parents=set()
registers={'rax':0,'rcx':1,'rdx':2,'rbx':3,'rsp':4,'rbp':5,'rsi':6,'rdi':7,
           **{f'r{i}':i for i in range(8,16)}}
source_registers={'eax':0,'ecx':1,'edx':2,'r14d':14,'r8d':8}
for root,spans in sorted(groups.items()):
    if not 0x1270000<=root<0x12B0000:continue
    instructions=[i for a,z,_ in spans for i in decoder.disasm(data[a:z],a)]
    writes=[i for i in instructions if any(o.type==CS_OP_MEM and o.access&CS_AC_WRITE
        and o.mem.disp in (0x1f8,0x1fc) and o.mem.base not in (X86_REG_RSP,X86_REG_RBP)
        for o in i.operands)]
    if not writes:continue
    assert not any(i.mnemonic.startswith('v') for i in instructions), 'AVX parent needs extended state preservation'
    for i in writes if root==0x1279190 else writes[-1:]:
        assert i.mnemonic=='mov' and len(i.operands)==2
        memory=i.operands[0].mem
        assert not memory.index and i.operands[0].size==4 and 5<=i.size<=8
        base=registers[decoder.reg_name(memory.base)]
        source=source_registers[decoder.reg_name(i.operands[1].reg)]
        parent=next(row for row in spans if row[0]<=i.address<row[1])
        sites.append((i.address,i.size,memory.disp,base,source,parent,bytes(i.bytes)))
        parents.add(root)
assert len(sites)==18 and len(parents)==17
lines=['// Generated build-specific guards. No captured image is distributed.', '#pragma once',
       '#include <cstdint>', '#include <windows.h>', 'namespace hob {',
       'struct QueueSiteGuard { uint32_t rva,length,field; uint8_t base,source; RUNTIME_FUNCTION parent; uint8_t bytes[8]; };',
       'inline constexpr QueueSiteGuard queue_site_guards[] = {']
for a,n,field,base,source,parent,code in sorted(sites):
    triple=','.join(f'0x{x:X}' for x in parent)
    raw=','.join(f'0x{x:02X}' for x in code)
    lines.append(f'    {{0x{a:X},{n},0x{field:X},{base},{source},{{{triple}}},{{{raw}}}}},')
lines+=['};', 'struct QueueSpanGuard { uint32_t rva,length; uint8_t sha256[32]; };',
        'inline constexpr QueueSpanGuard queue_span_guards[] = {']
count=0;total=0
for root in sorted(parents):
    for a,z,u in sorted(groups[root]):
        digest=hashlib.sha256(data[a:z]).digest()
        raw=','.join(f'0x{x:02X}' for x in digest)
        lines.append(f'    {{0x{a:X},0x{z-a:X},{{{raw}}}}},')
        count+=1;total+=z-a
lines+=['};','}']
output=Path(__file__).resolve().parent/'queue_profile.h'
output.write_text('\n'.join(lines)+'\n')
print(f'Generated {len(sites)} commit sites, {count} guarded code spans, {total} bytes; no AVX parents')
