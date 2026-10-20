#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "commit_stub.h"
#include "vendor/minhook/include/MinHook.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#define CHECK(x) do {if (!(x)) {std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);std::exit(1);}} while(0)
using Function=uint32_t (*)(void*,uint32_t);
static uint32_t before_count=0,after_count=0,expected=0,expected_field=0;
static uint64_t parent_low=0,parent_high=0;
static bool saw_parent=false;
static bool benchmarking=false;
static void (*clobber)()=nullptr;
static void before(uint64_t context,uint32_t value,uint32_t field) noexcept {
    CHECK(value==expected && field==expected_field);
    CHECK(*reinterpret_cast<uint32_t*>(context+field)!=expected);
    ++before_count;clobber();
    if (benchmarking) return;
    // Explicit dynamic-table-aware walking. CaptureStackBackTrace on this host
    // stops at private executable memory, despite valid RtlLookup/VirtualUnwind.
    CONTEXT context_record{};RtlCaptureContext(&context_record);
    for(unsigned j=0;j<8;++j) {
        if(context_record.Rip>=parent_low && context_record.Rip<parent_high)saw_parent=true;
        DWORD64 image_base=0;auto* entry=RtlLookupFunctionEntry(context_record.Rip,&image_base,nullptr);
        if (!entry)break;
        PVOID hd=nullptr;DWORD64 ef=0;
        RtlVirtualUnwind(0,image_base,context_record.Rip,entry,&context_record,&hd,&ef,nullptr);
    }
}
static void after(uint64_t context) noexcept {
    CHECK(*reinterpret_cast<uint32_t*>(context+expected_field)==expected);
    ++after_count;clobber();
}
struct Bytes {
    std::vector<uint8_t> b;
    void add(std::initializer_list<uint8_t> v) {b.insert(b.end(),v.begin(),v.end());}
    template<class T> void value(T v) {
        const auto* p=reinterpret_cast<const uint8_t*>(&v);b.insert(b.end(),p,p+sizeof v);
    }
};
static void store(Bytes& c,uint8_t base,uint8_t source,uint32_t field) {
    if(base>=8 || source>=8)c.add({static_cast<uint8_t>(0x40 | (base>=8?1:0) | (source>=8?4:0))});
    c.add({0x89,static_cast<uint8_t>(0x80 | ((source&7)<<3) | (base&7))});
    if((base&7)==4)c.add({0x24});
    c.value(field);
}
static void unwind_at(uint64_t pc,uint64_t rsp,uint64_t expected_rsp,uint64_t expected_rip) {
    DWORD64 image=0;
    auto* f=RtlLookupFunctionEntry(pc,&image,nullptr);CHECK(f);
    CONTEXT c{};c.ContextFlags=CONTEXT_FULL;c.Rip=pc;c.Rsp=rsp;
    PVOID data=nullptr;DWORD64 frame=0;
    RtlVirtualUnwind(UNW_FLAG_NHANDLER,image,pc,f,&c,&data,&frame,nullptr);
    CHECK(c.Rsp==expected_rsp && c.Rip==expected_rip);
}
int main() {
    constexpr uint32_t image_size=65536;
    auto* parent=static_cast<uint8_t*>(VirtualAlloc(nullptr,image_size,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    CHECK(parent);
    const uint64_t image=reinterpret_cast<uint64_t>(parent);
    const uint8_t bases[5]={7,12,13,3,3},sources[5]={0,8,2,1,14};
    uint32_t native_frame[5]{};
    std::vector<hob::CommitSite> sites;
    auto* functions=reinterpret_cast<RUNTIME_FUNCTION*>(parent+0x300);
    for(unsigned j=0;j<5;++j) {
        const uint8_t base=bases[j],source=sources[j];
        const uint32_t field=j%2?0x1f8:0x1fc,start=0x1000+j*0x100;
        Bytes c;
        if(base>=8)c.add({0x41});
        c.add({static_cast<uint8_t>(0x50+(base&7))});
        const uint8_t push_size=static_cast<uint8_t>(c.b.size());
        const bool source_nonvolatile=source==14;
        if(source_nonvolatile)c.add({0x41,0x56});
        const uint8_t second_push=static_cast<uint8_t>(c.b.size());
        const uint8_t allocation=source_nonvolatile?40:32;
        native_frame[j]=allocation+(source_nonvolatile?16:8);
        c.add({0x48,0x83,0xec,allocation});
        const uint8_t prologue=static_cast<uint8_t>(c.b.size());
        c.add({static_cast<uint8_t>(0x48 | (base>=8?1:0)),0x89,static_cast<uint8_t>(0xc8 | (base&7))});
        if(source>=8)c.add({0x41});
        c.add({0x89,static_cast<uint8_t>(0xd0 | (source&7))}); // value EDX -> selected source
        c.add({0x66,0x0f,0x6e,0xc2,0xf9}); // XMM0=value; carry set
        const uint32_t site=static_cast<uint32_t>(c.b.size());
        store(c,base,source,field);
        const uint32_t size=static_cast<uint32_t>(c.b.size())-site;
        c.add({0x73,0});const auto fail_carry=c.b.size()-1;
        c.add({0x66,0x0f,0x7e,0xc2}); // XMM0 -> EDX, verify it survived callback
        if(base>=8)c.add({0x41});
        c.add({0x3b,static_cast<uint8_t>(0x90 | (base&7))});
        if((base&7)==4)c.add({0x24});
        c.value(field);
        c.add({0x75,0});const auto fail_xmm=c.b.size()-1;
        if(base>=8)c.add({0x41});
        c.add({0x8b,static_cast<uint8_t>(0x80 | (base&7))});
        if((base&7)==4)c.add({0x24});
        c.value(field);
        c.add({0xeb,5});
        const auto failure=c.b.size();
        c.add({0xb8});c.value(uint32_t{0xdead});
        c.add({0x48,0x83,0xc4,allocation});
        if(source_nonvolatile)c.add({0x41,0x5e});
        if(base>=8)c.add({0x41});
        c.add({static_cast<uint8_t>(0x58+(base&7)),0xc3});
        c.b[fail_carry]=static_cast<uint8_t>(failure-(fail_carry+1));
        c.b[fail_xmm]=static_cast<uint8_t>(failure-(fail_xmm+1));
        std::memcpy(parent+start,c.b.data(),c.b.size());
        auto* uw=parent+0x200+j*16;
        uw[0]=1;uw[1]=prologue;uw[2]=source_nonvolatile?3:2;
        uw[4]=prologue;uw[5]=static_cast<uint8_t>(((allocation/8-1)<<4)|2);
        unsigned code=6;
        if(source_nonvolatile) {uw[code++]=second_push;uw[code++]=0xe0;}
        uw[code++]=push_size;uw[code]=static_cast<uint8_t>(base<<4);
        functions[j]={start,start+static_cast<DWORD>(c.b.size()),0x200+j*16};
        sites.push_back({image+start+site,size,field,base,source,functions[j]});
    }
    // A real chained native parent, as used by cold camera function fragments.
    parent[0x280]=static_cast<uint8_t>(1 | (UNW_FLAG_CHAININFO<<3));
    std::memcpy(parent+0x284,&functions[3],sizeof(RUNTIME_FUNCTION));
    functions[3].UnwindData=0x280;
    sites[3].parent=functions[3];
    const uint8_t corrupt[]={0x66,0x0f,0xef,0xc0,0xf8,0xc3};
    std::memcpy(parent+0x800,corrupt,sizeof corrupt);clobber=reinterpret_cast<void (*)()>(parent+0x800);
    DWORD previous=0;CHECK(VirtualProtect(parent,image_size,PAGE_EXECUTE_READ,&previous));
    CHECK(RtlAddFunctionTable(functions,5,image));
    hob::CommitArena arena;
    CHECK(hob::build_commit_stubs(image,image_size,sites,before,after,arena));
    CHECK(arena.stubs.size()==5);
    CHECK(MH_Initialize()==MH_OK);
    alignas(16) uint8_t stack[4096]{};
    constexpr uint32_t iterations=200000;
    double off_ns=0,on_ns=0;
    auto benchmark=[&](Function function,uint32_t field) {
        alignas(16) uint8_t context[1024]{};
        LARGE_INTEGER start{},end{},frequency{};QueryPerformanceFrequency(&frequency);
        expected_field=field;benchmarking=true;QueryPerformanceCounter(&start);
        for(uint32_t i=0;i<iterations;++i) {
            expected=4000+(i&1);
            CHECK(function(context,expected)==expected);
        }
        QueryPerformanceCounter(&end);benchmarking=false;
        return static_cast<double>(end.QuadPart-start.QuadPart)*1e9/static_cast<double>(frequency.QuadPart)/iterations;
    };
    for(unsigned j=0;j<5;++j) {
        const auto& stub=arena.stubs[j];const auto& site=sites[j];
        const uint64_t rsp=reinterpret_cast<uint64_t>(stack+2048);
        const uint64_t caller=reinterpret_cast<uint64_t>(&main);
        const uint64_t resume=site.instruction+site.instruction_size;
        std::memcpy(reinterpret_cast<void*>(rsp+native_frame[j]),&caller,8);
        std::memcpy(reinterpret_cast<void*>(rsp-8),&resume,8);
        unwind_at(stub.entry,rsp,rsp+native_frame[j]+8,caller);
        unwind_at(stub.body,rsp-8,rsp,resume);
        unwind_at(stub.pushed_flags,rsp-16,rsp,resume);
        unwind_at(stub.allocated,rsp-624,rsp,resume);
        unwind_at(stub.pop_flags,rsp-632,rsp,resume);
        unwind_at(stub.restored_flags,rsp-624,rsp,resume);
        unwind_at(stub.returning,rsp-8,rsp,resume);
        if(j==0)off_ns=benchmark(reinterpret_cast<Function>(image+functions[j].BeginAddress),site.field);
        // Only this fixture's private code is patched, never the game.
        void* trampoline=nullptr;
        CHECK(MH_CreateHook(reinterpret_cast<void*>(site.instruction),reinterpret_cast<void*>(stub.entry),&trampoline)==MH_OK);
        CHECK(MH_EnableHook(reinterpret_cast<void*>(site.instruction))==MH_OK);
        const auto* patch=reinterpret_cast<const uint8_t*>(site.instruction);
        int32_t jump=0;std::memcpy(&jump,patch+1,4);
        CHECK(patch[0]==0xe9 && site.instruction+5+jump==stub.entry);
        alignas(16) uint8_t context[1024]{};
        parent_low=image+functions[j].BeginAddress;parent_high=image+functions[j].EndAddress;
        saw_parent=false;
        expected_field=site.field;expected=123+j;
        const auto result=reinterpret_cast<Function>(parent_low)(context,expected);
        CHECK(result==expected);
        CHECK(*reinterpret_cast<uint32_t*>(context+site.field)==expected);
        CHECK(saw_parent);
        if(j==0)on_ns=benchmark(reinterpret_cast<Function>(parent_low),site.field);
        CHECK(MH_DisableHook(reinterpret_cast<void*>(site.instruction))==MH_OK);
    }
    CHECK(before_count==5+iterations && after_count==5+iterations && saw_parent);
    std::printf("THUNK_BENCH events=%u off_ns=%.1f on_ns=%.1f delta_ns=%.1f (fixture only, excludes game witness and HoB consumer)\n",iterations,off_ns,on_ns,on_ns-off_ns);
    std::puts("PASS commit branches: real writes, pre/post ordering, carry/XMM preservation, all seven unwind boundaries and native parent stack walks");
}
