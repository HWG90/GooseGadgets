"""Read-only validation of the candidate against the game's decoded catalogues.

Uses the already installed Link's Link to Memory diagnostic channel. Never loads
main.lua, calls apply/restore, installs a mod, or writes game/profile memory.
Retains private diagnostic output only under this mod's ignored dist/research.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(os.environ['LOCALAPPDATA']) / 'LinksLinkToMemory'


def literal(text):
    # Lua 5.1 decimal escapes preserve every UTF-8 byte and keep the bridge's
    # line-oriented command protocol to exactly one command.
    return '"' + ''.join('\\%03d' % b for b in text.encode('utf-8')) + '"'


def main():
    sys.path.insert(0, str(BRIDGE / 'relay'))
    import relay
    sources = {name: (ROOT / name).read_text(encoding='utf-8')
               for name in ('src/catalogue.lua', 'src/memory.lua', 'src/customization.lua', 'src/backend.lua')}
    # loadstring closes over its isolated module environment; normal host
    # require only supplies the existing ffi/bit libraries. No lifecycle runs.
    command = '''eval
local sources={%s}
local cache={}
local env=setmetatable({}, {__index=_G})
env.mod={require=function(name)
    if cache[name] then return cache[name] end
    local fn=assert(loadstring(assert(sources[name]),'@ShearReadOnly/'..name))
    setfenv(fn,env);cache[name]=fn();return cache[name]
end}
local backend=env.mod.require('src/backend.lua').new()
local ffi=require('ffi')
pcall(ffi.cdef,'int ShearInspect_QPC(int64_t *) __asm__("QueryPerformanceCounter"); int ShearInspect_QPF(int64_t *) __asm__("QueryPerformanceFrequency");')
local k=ffi.load('kernel32')
local ticks,hz=ffi.new('int64_t[1]'),ffi.new('int64_t[1]')
assert(k.ShearInspect_QPF(hz)~=0)
assert(k.ShearInspect_QPC(ticks)~=0);local start=tonumber(ticks[0])
local plan,why=backend:prepare()
assert(k.ShearInspect_QPC(ticks)~=0);local ms=(tonumber(ticks[0])-start)*1000/tonumber(hz[0])
assert(plan,why)
local C=env.mod.require('src/catalogue.lua')
out('SHEAR_READ_ONLY_VALID',plan.context.count,#plan.edits,string.format('%%.3f',ms))
for _,edit in ipairs(plan.edits)do out('EDIT',string.format('%%X',edit.offset),#edit.before,#edit.after)end
out('NEW_RECORD',hex(plan.edits[1].after))
out('NATIVE_RESOURCE','7e3145a5baa4b948','NATIVE_ID','7DE53646')
return 'No game memory writes or native game calls performed'
''' % ','.join('[' + literal(name) + ']=' + literal(source) for name, source in sources.items())
    command = ' '.join(command.splitlines())
    result = relay.run_when_idle([command], timeout=25)
    folder = ROOT / 'dist/research'
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'read-only-validation.txt').write_text(result, encoding='utf-8')
    game = Path(r'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2\data\game')
    receipt = {'game_stamp': '6AB3B43F', 'mode': 'read-only', 'sources': {
        name: hashlib.sha256(source.encode()).hexdigest() for name, source in sources.items()},
        'installed_game_files': {name: hashlib.sha256((game / name).read_bytes()).hexdigest()
            for name in ('game.dll', 'generated_entities.dl_bin', 'generated_weapon_customization_settings.dl_bin')}}
    match = re.search(r'SHEAR_READ_ONLY_VALID (\d+) (\d+) ([\d.]+)', result)
    receipt['validated'] = bool(match)
    if match:
        receipt.update(count=int(match[1]), edits=int(match[2]), prepare_ms=float(match[3]))
    (folder / 'read-only-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    # Suppress source echoes and any continuation lines; show acknowledged
    # timestamped results, timing and errors only.
    for line in result.splitlines():
        if re.match(r'^\d\d:\d\d:\d\d (?!> eval)', line):
            print(line)
    return 0 if match else 1


if __name__ == '__main__':
    raise SystemExit(main())
