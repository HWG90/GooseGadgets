"""Execute the production branch-cave generator in an isolated x64 emulator."""
import argparse
import ctypes
from pathlib import Path
import struct
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('dll', type=Path)
    parser.add_argument('--deps', type=Path, required=True)
    options = parser.parse_args()
    sys.path.insert(0, str(options.deps.resolve()))
    from unicorn import Uc, UC_ARCH_X86, UC_MODE_64, UC_HOOK_CODE
    from unicorn import x86_const as x
    library = ctypes.CDLL(str(options.dll.resolve()))
    recipe = library.BC_health_cave_recipe
    recipe.argtypes = [ctypes.c_uint64]*3 + [ctypes.c_void_p, ctypes.c_size_t]
    recipe.restype = ctypes.c_size_t
    offsets_fn = library.BC_health_owner_offsets
    offsets_fn.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    offsets_fn.restype = ctypes.c_size_t
    count = offsets_fn(None, 0)
    offsets_array = (ctypes.c_uint32 * count)()
    assert count == 11 and offsets_fn(offsets_array, count) == count
    fields = 'enabled game state pm health health_runtime health_descriptor avatar player world local_unit'.split()
    offsets = dict(zip(fields, offsets_array))
    game, code_address, owner_address, lease_address = 0x4000000, 0x1000000, 0x2000000, 0x2010000
    size = recipe(game, owner_address, lease_address, None, 0)
    buffer = (ctypes.c_uint8 * size)()
    assert recipe(game, owner_address, lease_address, buffer, size) == size
    code = bytes(buffer)
    state, pm, health, runtime, descriptor, player, world = [0x3000000 + i*0x100000 for i in range(7)]
    avatar, unit = 1060, 91777
    owner_values = dict(enabled=1, game=game, state=state, pm=pm, health=health,
                        health_runtime=runtime, health_descriptor=descriptor, avatar=avatar,
                        player=player, world=world, local_unit=unit)
    registers = [getattr(x, 'UC_X86_REG_'+name) for name in
                 ['RAX','RBX','RCX','RDX','RSI','RDI','RBP','RSP','R8','R9','R10','R11','R12','R13','R14','R15']]
    continued, blocked = game + 0x9238BF, game + 0x925D31
    cases = [('local ship actor', {}, True), ('normal mission path', {'zf': False}, True)]
    for key in fields:
        if key != 'game': cases.append(('foreign '+key, {'owner_'+key: 0}, False))
    cases += [('health lease retired', {'allowed': 0}, False),
              ('health manager replaced', {'global_health': health+8}, False),
              ('player manager replaced', {'global_pm': pm+8}, False),
              ('game state replaced', {'global_state': state+8}, False),
              ('player replaced', {'global_player': player+8}, False),
              ('world replaced', {'global_world': world+8}, False),
              ('local actor replaced', {'player_unit': unit+1}, False),
              ('descriptor actor changed', {'descriptor_avatar': avatar+1}, False),
              ('descriptor retired', {'live': 0}, False)]
    for name, changes, allow in cases:
        emulator = Uc(UC_ARCH_X86, UC_MODE_64)
        pages = set()
        def put(address, data):
            for page in range(address & ~4095, (address+len(data)+4095)&~4095, 4096):
                if page not in pages: emulator.mem_map(page,4096); pages.add(page)
            emulator.mem_write(address,data)
        put(code_address,code)
        for field, value in owner_values.items():
            value = changes.get('owner_'+field, value)
            kind = '<I' if field in ('enabled','avatar','local_unit') else '<Q'
            put(owner_address+offsets[field], struct.pack(kind,value))
        put(lease_address,struct.pack('<I',changes.get('allowed',1)))
        for off, key, value in [(0x3326688,'health',health),(0x3326D20,'pm',pm),(0x3326340,'state',state),
                                (0x3326468,'player',player),(0x346BF98,'world',world)]:
            put(game+off,struct.pack('<Q',changes.get('global_'+key,value)))
        put(player+0x3A8,struct.pack('<I',changes.get('player_unit',unit)))
        put(descriptor+8,struct.pack('<I',changes.get('descriptor_avatar',avatar)))
        put(descriptor+0x14,bytes([changes.get('live',1)]))
        stack, frame = 0x800F000, 0x8001000
        put(stack-4096,bytes(4096));put(frame-0x60,struct.pack('<Q',descriptor))
        put(continued,b'\xcc');put(blocked,b'\xcc')
        for i, reg in enumerate(registers): emulator.reg_write(reg,0xCAFE0000+i)
        for reg,value in [(x.UC_X86_REG_RAX,state),(x.UC_X86_REG_RBX,0xC0FFEE0000000000|avatar),
                          (x.UC_X86_REG_R12,health),(x.UC_X86_REG_R15,runtime),
                          (x.UC_X86_REG_RBP,frame),(x.UC_X86_REG_RSP,stack)]: emulator.reg_write(reg,value)
        flags = 0x246 if changes.get('zf',True) else 0x202
        emulator.reg_write(x.UC_X86_REG_EFLAGS,flags)
        before = [emulator.reg_read(reg) for reg in registers]
        result = []
        def reached(machine,address,size,data):
            if address in (continued,blocked): result.append(address); machine.emu_stop()
        emulator.hook_add(UC_HOOK_CODE,reached)
        emulator.emu_start(code_address,0,count=200)
        assert result == [continued if allow else blocked], (name,result)
        assert before == [emulator.reg_read(reg) for reg in registers], name+' changed registers'
        assert emulator.reg_read(x.UC_X86_REG_EFLAGS) == flags, name+' changed flags'
    print(f'{len(cases)} native health cave cases passed; registers, stack, flags preserved; {size} bytes')


if __name__ == '__main__': main()
