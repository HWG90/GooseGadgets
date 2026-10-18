"""Offline fixture and saved-package validation; never access a game process."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import zipfile

ROOT=Path(__file__).resolve().parents[1]
TEST_FILES=('parameters.lua','ads_gate_test.lua','prototype.lua','backend_prototype.lua','scheduling.lua','bsl.lua','loader_prototype.lua')
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

def main(dll_path=None):
    runner=load('lua_runner',ROOT/'tests/run_tests.py')
    runner.ROOT=ROOT
    lll=load('lll_builder',ROOT/'tools/build.py')
    bsl=load('bsl_builder',ROOT/'tools/build_bsl.py')
    manifest=json.loads((ROOT/'manifest.json').read_text())
    lll.validate_manifest(manifest)
    assert json.loads((ROOT/'config/defaults.cfg').read_text())=={'enabled':False}
    outputs=[]
    for builder in (lll,bsl):
        archive=builder.build()
        original=archive.read_bytes()
        assert builder.build().read_bytes()==original, 'Non-deterministic package'
        with zipfile.ZipFile(archive) as package:
            assert package.testzip() is None
            for name in package.namelist():
                assert '..' not in Path(name).parts
                assert not name.lower().endswith(('.dll','.exe','.pdb','.log'))
        outputs.append({'path':str(archive),'sha256':hashlib.sha256(original).hexdigest()})
    code=runner.run_lua(dll_path if dll_path is not None else runner.DEFAULT_DLL,TEST_FILES)
    if code:return code
    receipt={'state':'offline fixtures and deterministic package checks passed; not installed or live-proven',
        'test_files':list(TEST_FILES),
        'packages':outputs,
        'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                   for d in ('src','tests') for p in sorted((ROOT/d).glob('*.lua'))
                   if d=='src' or p.name in TEST_FILES}}
    (ROOT/'dist/releases/PROTOTYPE-VALIDATION.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(outputs,indent=2))
    return 0
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',type=Path,help='Path to a local LuaJIT lua51.dll')
    args=parser.parse_args()
    sys.exit(main(args.dll))
