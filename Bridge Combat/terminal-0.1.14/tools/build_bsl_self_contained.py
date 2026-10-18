"""Combine validated Bridge Combat and local distribution dependencies; never deploy."""
from pathlib import Path
import argparse
import hashlib
import json
import zipfile
import build_bsl as b

ROOT = b.ROOT
MODS = Path('C:/Users/david/AppData/Local/hd2arsenal/mods')
OUT = ROOT / 'dist/releases/bridge-combat-0.1.14-bsl-self-contained-test'

def main():
    global MODS, OUT
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mods-root',type=Path,default=MODS)
    parser.add_argument('--addon',type=Path,default=ROOT/'dist/releases/bridge-combat-0.1.14-experimental-bsl-review')
    parser.add_argument('--output',type=Path,default=OUT)
    args=parser.parse_args();MODS=args.mods_root.resolve();OUT=args.output.resolve()
    loader = next(MODS.glob('Bingus Shared Loader*/data/9ba626afa44a3aa3.patch_0'))
    pack = next(MODS.glob('Vanilla Plus Megapack*'))
    mcm = MODS / 'DBF-MCM-Standalone-0.1.66_AR484799'
    addon = args.addon.resolve()
    inputs = [loader, pack/'options/ModOptionsMenu/9ba626afa44a3aa3.patch_0',
              pack/'options/ModBindingsMenu/9ba626afa44a3aa3.patch_0',
              mcm/'Addon/9ba626afa44a3aa3.patch_0']
    entries = {}
    provenance = {}
    for path in inputs:
        data = path.read_bytes()
        provenance[str(path)] = b.sha256(data)
        for key, (kind, body) in b.lua_archive.read(data).items():
            assert kind == b.lua_archive.LUA_TYPE
            if path.parent.name in ('ModOptionsMenu', 'ModBindingsMenu'):
                expected = 'mods/cowboybingus/' + ('mod_options_menu' if path.parent.name == 'ModOptionsMenu' else 'mod_bindings_menu')
                if key != b.lua_archive.hash_name(expected): continue
            assert key not in entries, 'Dependency resource collision'
            entries[key] = body
    with zipfile.ZipFile(addon/'BridgeCombat-0.1.14-experimental-BSL.zip') as z:
        for key, (kind, body) in b.lua_archive.read(z.read('Addon/'+b.ARCHIVE)).items():
            assert key not in entries and kind == b.lua_archive.LUA_TYPE
            entries[key] = body
    archive = b.lua_archive.write(entries)
    assert b.lua_archive.read(archive) == {key:(b.lua_archive.LUA_TYPE, body) for key,body in entries.items()}
    description = 'Self-contained Bridge Combat 0.1.14 BSL test: includes BSL v19, Mod Options, Mod Bindings, standalone DBF-MCM, screen render dispatcher and native helper.'
    manifest = {'Version':1,'Guid':b.GUID,'Author':'Goose','Name':'Bridge Combat - Self-contained BSL Test',
                'Description':description,'Options':[{'Name':'Complete test package','Description':description,'Include':['Addon']}]}
    readme = '''Bridge Combat 0.1.14 - SELF-CONTAINED BSL TEST

Import this ZIP in Arsenal or HD2MM and enable its Complete test package option.
All mod dependencies are included. No separate BSL, MCM, HUD, LLL or menu downloads.
Disable separate Bridge Combat variants and duplicate loader/menu/MCM packages
for this test. Give this package winning priority for the shared startup resource.
Deploy through your manager, then start the game normally.

Open ESC > MODS > Bridge Combat. Enable combat and Wall terminal.
The console has a fixed default location beside the Armory. Interact to use it.
Interact focuses the camera and releases it on a second press; Escape also exits.
The terminal uses a sharp 4096x2560 target with reduced screen emission.
Select a weapon and press EQUIP SELECTED. Requests enable combat automatically.
WEAPONS FREE enables combat and reflects its flag in red.
Public menus do not offer repositioning controls.

Included: Bingus Shared Loader v19; original Mod Options Menu and Mod Bindings
Menu from Vanilla Plus Megapack v41; DBF-MCM standalone 0.1.66; Bridge Combat
0.1.14 runtime and content-hashed native helper; embedded render dispatcher.
The other Vanilla Plus gameplay mods are NOT included.

Offline validated experimental build. BSL gameplay is not live-proven.
LLL gameplay has been tested; this BSL distribution has offline validation only.
No settings, game assets, logs or private research are bundled.
This archive does not install itself or launch the game.
'''
    payload = {'manifest.json':b.json_bytes(manifest), 'Addon/'+b.ARCHIVE:archive,
               'Addon/'+b.ARCHIVE+'.stream':b'', 'Addon/'+b.ARCHIVE+'.gpu_resources':b'',
               'README-TEST.txt':readme.encode(), 'LICENSE-BridgeCombat.txt':(ROOT/'LICENSE').read_bytes(),
               'TERMINAL-ICONS.md':(b.COMPAT/'TERMINAL-ICONS.md').read_bytes()}
    for source, name in [(loader.parent.parent/'BingusSharedLoader-README.txt','BSL-README.txt'),
                         (pack/'VanillaPlusMegapack-README.txt','VanillaPlus-README.txt'),
                         (mcm/'CREDITS.md','MCM-CREDITS.md'),
                         (mcm/'LICENSE-CowboyBingus.txt','LICENSE-CowboyBingus.txt')]:
        payload['Notices/'+name] = source.read_bytes()
    OUT.mkdir(parents=True,exist_ok=True)
    target = OUT/'BridgeCombat-0.1.14-BSL-SelfContained-Test.zip'
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        for name, body in sorted(payload.items()): z.writestr(name,body)
    with zipfile.ZipFile(target) as z:
        assert z.testzip() is None and set(z.namelist()) == set(payload)
        assert all(z.read(name)==body for name,body in payload.items())
    digest = b.sha256(target.read_bytes())
    (OUT/'build-manifest.json').write_bytes(b.json_bytes({'archive':target.name,'sha256':digest,
        'resources':len(entries),'dependency_inputs':provenance,
        'files':{name:b.sha256(body) for name,body in payload.items()},
        'state':'Offline test package; not deployed or live-proven'}))
    (OUT/'SHA256SUMS.txt').write_text(digest+'  '+target.name+'\n')
    print(target)
    print('PASS resource round-trip, unique resources, ZIP integrity and payload hash readback')

if __name__ == '__main__': main()
