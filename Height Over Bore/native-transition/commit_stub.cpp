#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "commit_stub.h"
#include <cstring>
#include <limits>

namespace hob {
namespace {
constexpr uint32_t frame=616, locals=608;
constexpr uint8_t volatile_regs[7]={0,1,2,8,9,10,11};
struct Code {
    std::vector<uint8_t> b;
    void byte(uint8_t x) { b.push_back(x); }
    void bytes(std::initializer_list<uint8_t> values) {b.insert(b.end(),values.begin(),values.end());}
    template<class T> void value(T x) {
        const auto* p=reinterpret_cast<const uint8_t*>(&x);b.insert(b.end(),p,p+sizeof x);
    }
    void reg_arg(uint8_t destination,uint8_t source) {
        byte(static_cast<uint8_t>(0x48 | (source>=8?4:0) | (destination>=8?1:0)));
        byte(0x89);byte(static_cast<uint8_t>(0xc0 | ((source&7)<<3) | (destination&7)));
    }
    void save(uint8_t reg,uint8_t offset,bool restore) {
        byte(static_cast<uint8_t>(0x48 | (reg>=8?4:0)));byte(restore?0x8b:0x89);
        byte(static_cast<uint8_t>(0x44 | ((reg&7)<<3)));byte(0x24);byte(offset);
    }
    void source32(uint8_t destination,uint8_t source) {
        for (unsigned i=0;i<7;++i) if (volatile_regs[i]==source) {
            bytes({0x8b,static_cast<uint8_t>(0x44 | (destination<<3)),0x24,
                static_cast<uint8_t>(32+i*8)});return;
        }
        if (source>=8) byte(0x44);
        bytes({0x89,static_cast<uint8_t>(0xc0 | ((source&7)<<3) | destination)});
    }
    void call(uint64_t target) {bytes({0x48,0xb8});value(target);bytes({0xff,0xd0});}
};
uint64_t align(uint64_t value,uint64_t size) noexcept {return (value+size-1)&~(size-1);}
void* allocate_above(uint64_t image,uint32_t size,uint32_t bytes) noexcept {
    SYSTEM_INFO info{};GetSystemInfo(&info);
    const uint64_t granularity=info.dwAllocationGranularity;
    uint64_t at=align(image+size,granularity);
    const uint64_t limit=image+0x70000000;
    while (at+bytes<limit) {
        MEMORY_BASIC_INFORMATION region{};
        if (VirtualQuery(reinterpret_cast<void*>(at),&region,sizeof region)!=sizeof region) return nullptr;
        if (region.State==MEM_FREE) {
            void* result=VirtualAlloc(reinterpret_cast<void*>(at),bytes,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
            if (result) return result;
            if (GetLastError()==ERROR_ACCESS_DENIED) return nullptr;
        }
        const uint64_t next=reinterpret_cast<uint64_t>(region.BaseAddress)+region.RegionSize;
        if (next<=at) return nullptr;
        at=align(next,granularity);
    }
    return nullptr;
}
struct Made {
    Code code;
    uint32_t body=0,pushed=0,allocated=0,pop=0,restored=0,returning=0,end=0;
};
Made make(const CommitSite& site,BeforeCommit before,AfterCommit after) {
    Made m; auto& c=m.code;
    // This synthetic return address makes the callback body a normal Win64
    // frame. The prefix has its own unwind entry chained to the native frame.
    c.bytes({0xff,0x35,0,0,0,0});m.body=static_cast<uint32_t>(c.b.size());
    c.byte(0x9c);m.pushed=static_cast<uint32_t>(c.b.size());
    c.bytes({0x48,0x81,0xec});c.value(locals);m.allocated=static_cast<uint32_t>(c.b.size());
    for(unsigned i=0;i<7;++i)c.save(volatile_regs[i],static_cast<uint8_t>(32+i*8),false);
    c.bytes({0x48,0x0f,0xae,0x44,0x24,0x60}); // FXSAVE64, aligned +96
    c.reg_arg(1,site.base_register);c.source32(2,site.source_register);
    c.bytes({0x41,0xb8});c.value(site.field);c.call(reinterpret_cast<uint64_t>(before));
    c.source32(0,site.source_register);
    if (site.base_register>=8)c.byte(0x41);
    c.bytes({0x89,static_cast<uint8_t>(0x80 | (site.base_register&7))});
    if ((site.base_register&7)==4)c.byte(0x24);
    c.value(site.field); // the single original 32-bit store, exactly once
    c.reg_arg(1,site.base_register);c.call(reinterpret_cast<uint64_t>(after));
    c.bytes({0x48,0x0f,0xae,0x4c,0x24,0x60}); // FXRSTOR64
    for(unsigned i=1;i<7;++i)c.save(volatile_regs[i],static_cast<uint8_t>(32+i*8),true);
    c.bytes({0xff,0xb4,0x24});c.value(locals); // push saved original flags
    m.pop=static_cast<uint32_t>(c.b.size());c.byte(0x9d);
    m.restored=static_cast<uint32_t>(c.b.size());
    c.save(0,32,true);
    c.bytes({0x48,0x8d,0xa4,0x24});c.value(frame); // LEA preserves restored flags
    m.returning=static_cast<uint32_t>(c.b.size());c.byte(0xc3);
    m.end=static_cast<uint32_t>(c.b.size());
    while (c.b.size()%8)c.byte(0xcc);
    const auto literal=static_cast<int32_t>(c.b.size()-6);
    std::memcpy(c.b.data()+2,&literal,sizeof literal);
    c.value(site.instruction+site.instruction_size);
    return m;
}
}
bool build_commit_stubs(uint64_t base,uint32_t image_size,const std::vector<CommitSite>& sites,
    BeforeCommit before,AfterCommit after,CommitArena& output) noexcept {
    if (!base || !image_size || sites.empty() || sites.size()>64 || !before || !after || output.allocation) return false;
    try {
        std::vector<Made> made;
        uint32_t code_bytes=0;
        for (const auto& s:sites) {
            // Native context registers are nonvolatile. No implicit index/base
            // arithmetic, flags-changing store or unverified instruction form.
            if (s.base_register!=3 && s.base_register!=6 && s.base_register!=7
                && s.base_register!=12 && s.base_register!=13 && s.base_register!=15) return false;
            if (s.source_register>15 || (s.field!=0x1f8 && s.field!=0x1fc)
                || s.instruction_size<5 || s.instruction_size>8
                || s.instruction<base || s.instruction-base>=image_size
                || s.parent.BeginAddress>s.instruction-base || s.parent.EndAddress<=s.instruction-base) return false;
            made.push_back(make(s,before,after));
            code_bytes=static_cast<uint32_t>(align(code_bytes,16)+made.back().code.b.size());
        }
        code_bytes=static_cast<uint32_t>(align(code_bytes,4096));
        const uint32_t metadata_bytes=static_cast<uint32_t>(align(sites.size()*5*sizeof(RUNTIME_FUNCTION)+sites.size()*80,4096));
        const uint32_t bytes=code_bytes+metadata_bytes;
        auto* allocation=static_cast<uint8_t*>(allocate_above(base,image_size,bytes));
        if (!allocation) return false;
        // Retain even on failure. No thread can execute an unregistered stub;
        // after registration there may be a cached stack walk or instruction IP.
        output.allocation=reinterpret_cast<uint64_t>(allocation);output.image_base=base;output.bytes=bytes;
        auto* table=reinterpret_cast<RUNTIME_FUNCTION*>(allocation+code_bytes);
        auto* metadata=reinterpret_cast<uint8_t*>(table+sites.size()*5);
        auto rva=[&](const void* p)->DWORD {return static_cast<DWORD>(reinterpret_cast<uint64_t>(p)-base);};
        auto unwind_alloc=[&](uint32_t n)->DWORD {
            auto* p=metadata;metadata+=8;
            p[0]=1;p[1]=0;p[2]=2;p[3]=0;p[4]=0;p[5]=1;
            const uint16_t scaled=static_cast<uint16_t>(n/8);std::memcpy(p+6,&scaled,2);
            return rva(p);
        };
        uint32_t offset=0;
        for(unsigned i=0;i<sites.size();++i) {
            offset=static_cast<uint32_t>(align(offset,16));
            auto* code=allocation+offset;auto& m=made[i];
            std::memcpy(code,m.code.b.data(),m.code.b.size());
            auto* prefix=metadata;metadata+=16;
            prefix[0]=static_cast<uint8_t>(1 | (UNW_FLAG_CHAININFO<<3));
            std::memcpy(prefix+4,&sites[i].parent,sizeof(RUNTIME_FUNCTION));
            auto* prologue=metadata;metadata+=12;
            prologue[0]=1;prologue[1]=8;prologue[2]=3;prologue[3]=0;
            prologue[4]=8;prologue[5]=1;
            const uint16_t scaled=locals/8;std::memcpy(prologue+6,&scaled,2);
            prologue[8]=1;prologue[9]=2; // PUSHFQ is eight bytes of stack allocation
            const DWORD temporary=unwind_alloc(frame+8),established=unwind_alloc(frame);
            auto* leaf=metadata;metadata+=4;leaf[0]=1;
            table[i*5+0]={rva(code),rva(code+m.body),rva(prefix)};
            table[i*5+1]={rva(code+m.body),rva(code+m.pop),rva(prologue)};
            table[i*5+2]={rva(code+m.pop),rva(code+m.restored),temporary};
            table[i*5+3]={rva(code+m.restored),rva(code+m.returning),established};
            table[i*5+4]={rva(code+m.returning),rva(code+m.end),rva(leaf)};
            output.stubs.push_back({reinterpret_cast<uint64_t>(code),reinterpret_cast<uint64_t>(code+m.body),
                reinterpret_cast<uint64_t>(code+m.pushed),reinterpret_cast<uint64_t>(code+m.allocated),
                reinterpret_cast<uint64_t>(code+m.pop),reinterpret_cast<uint64_t>(code+m.restored),
                reinterpret_cast<uint64_t>(code+m.returning),m.end});
            offset+=static_cast<uint32_t>(m.code.b.size());
        }
        DWORD old=0;
        if (!VirtualProtect(allocation,code_bytes,PAGE_EXECUTE_READ,&old)
            || !VirtualProtect(allocation+code_bytes,metadata_bytes,PAGE_READONLY,&old)) return false;
        FlushInstructionCache(GetCurrentProcess(),allocation,code_bytes);
        return RtlAddFunctionTable(table,static_cast<DWORD>(sites.size()*5),base)!=0;
    } catch (...) {return false;}
}
}
