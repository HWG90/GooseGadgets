#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include "game_binding.h"
#include "queue_profile.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>
#define CHECK(x) do {if(!(x)){std::fprintf(stderr,"line %d: %s\n",__LINE__,#x);std::exit(1);}}while(0)
int main(int argc,char** argv) {
    CHECK(argc==2);
    std::ifstream input(argv[1],std::ios::binary|std::ios::ate);CHECK(input);
    const auto length=input.tellg();CHECK(length==0x4744000);
    auto* image=static_cast<uint8_t*>(VirtualAlloc(nullptr,static_cast<SIZE_T>(length),MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    CHECK(image);input.seekg(0);CHECK(input.read(reinterpret_cast<char*>(image),length));
    auto* dos=reinterpret_cast<IMAGE_DOS_HEADER*>(image);
    CHECK(dos->e_magic==IMAGE_DOS_SIGNATURE && dos->e_lfanew>=64 && dos->e_lfanew<=4096);
    auto* nt=reinterpret_cast<IMAGE_NT_HEADERS64*>(image+dos->e_lfanew);
    CHECK(nt->Signature==IMAGE_NT_SIGNATURE && nt->FileHeader.TimeDateStamp==0x6AB3B43F);
    auto* world=static_cast<uint8_t*>(VirtualAlloc(nullptr,0xF10000,MEM_RESERVE,PAGE_NOACCESS));CHECK(world);
    const auto world_address=reinterpret_cast<uint64_t>(world);
    const uint64_t implementation=world_address+0x40,base=reinterpret_cast<uint64_t>(image);
    for(const uint32_t offset:{0xF0DCA8U,0xF0E6C8U}) {
        const uint64_t slot=implementation+offset;
        CHECK(VirtualAlloc(reinterpret_cast<void*>(slot&~uint64_t{4095}),4096,MEM_COMMIT,PAGE_READWRITE));
        const uint64_t target=base+(offset==0xF0DCA8U?0x53FF20:0x540070);
        std::memcpy(reinterpret_cast<void*>(slot),&target,8);
    }
    std::memcpy(image+0x346BF98,&world_address,8);std::memcpy(image+0x346BFC8,&implementation,8);
    const uint64_t shutdown=base+0x4EE7F0;std::memcpy(image+0x37CEBB0,&shutdown,8);
    DWORD previous=0;CHECK(VirtualProtect(image,static_cast<SIZE_T>(length),PAGE_READONLY,&previous));
    uint64_t targets[4]{},retire_slot=0,shutdown_slot=0;
    CHECK(hob::inspect_module_profile(base,targets,retire_slot,shutdown_slot));
    CHECK(retire_slot==implementation+0xF0E6C8 && shutdown_slot==base+0x37CEBB0);
    const auto real_retire=*reinterpret_cast<uint64_t*>(retire_slot);
    *reinterpret_cast<uint64_t*>(retire_slot)=base+0x53FF20;
    CHECK(!hob::inspect_module_profile(base,targets,retire_slot,shutdown_slot));
    *reinterpret_cast<uint64_t*>(retire_slot)=real_retire;
    std::vector<RUNTIME_FUNCTION> table;
    for(const auto& g:hob::queue_site_guards)table.push_back(g.parent);
    std::sort(table.begin(),table.end(),[](const auto& a,const auto& b){return a.BeginAddress<b.BeginAddress;});
    table.erase(std::unique(table.begin(),table.end(),[](const auto& a,const auto& b){
        return std::memcmp(&a,&b,sizeof a)==0;}),table.end());
    CHECK(RtlAddFunctionTable(table.data(),static_cast<DWORD>(table.size()),base));
    std::vector<hob::CommitSite> admitted;
    CHECK(hob::admit_commit_sites(base,admitted) && admitted.size()==18);
    for(size_t i=0;i<admitted.size();++i) {
        CHECK(admitted[i].instruction==base+hob::queue_site_guards[i].rva);
        CHECK(admitted[i].instruction_size==hob::queue_site_guards[i].length);
    }
    auto* changed=image+0x127DE20;
    CHECK(VirtualProtect(changed,1,PAGE_READWRITE,&previous));*changed^=1;
    CHECK(VirtualProtect(changed,1,PAGE_READONLY,&previous));
    std::vector<hob::CommitSite> rejected;
    CHECK(!hob::admit_commit_sites(base,rejected) && rejected.empty());
    CHECK(VirtualProtect(changed,1,PAGE_READWRITE,&previous));*changed^=1;
    CHECK(VirtualProtect(changed,1,PAGE_READONLY,&previous));
    table[0].UnwindData^=4;
    CHECK(!hob::admit_commit_sites(base,rejected) && rejected.empty());
    table[0].UnwindData^=4;
    CHECK(hob::admit_commit_sites(base,rejected) && rejected.size()==18);
    MEMORY_BASIC_INFORMATION region{};CHECK(VirtualQuery(image,&region,sizeof region)==sizeof region);
    CHECK(region.Protect==PAGE_READONLY); // game bytes were never executable
    CHECK(RtlDeleteFunctionTable(table.data()));
    CHECK(VirtualFree(image,0,MEM_RELEASE));
    CHECK(VirtualFree(world,0,MEM_RELEASE));
    std::puts("PASS native admission: module/lifecycle identity, foreign callback rejection, 71 SHA-256 code guards, 18 actual unwind entries, altered-code and altered-unwind rejection; game image never executable");
}
