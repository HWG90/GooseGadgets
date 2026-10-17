"""Build the native review helper; no install, load, or game mutation."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--test-api', action='store_true')
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    objects = output / 'objects'
    objects.mkdir(exist_ok=True)
    native = ROOT / 'native'
    vendor = native / 'vendor' / 'minhook'
    setup = Path(r'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat')
    if not setup.is_file():
        raise SystemExit(f'MSVC x64 setup missing: {setup}')
    sources = [native / name for name in ('core.cpp', 'mode.cpp', 'actor.cpp')]
    for source in sources:
        if not source.is_file():
            raise SystemExit(f'Native module not ready: {source}')
    args = ['cl.exe', '/nologo', '/LD', '/MT', '/O2', '/EHsc', '/std:c++17', '/W4',
            f'/I{native}', f'/I{vendor / "include"}',
            f'/Fo{objects}\\', f'/Fe{output / "BridgeCombatNative.dll"}']
    args += [str(source) for source in sources]
    if options.test_api:
        args += ['/DBC_NATIVE_TEST_API']
    args += ['/link', '/INCREMENTAL:NO', '/OPT:REF', '/OPT:ICF']
    command = f'call "{setup}" >nul && {subprocess.list2cmdline(args)}'
    # /C consumes shell syntax, not CRT argv: list2cmdline would turn the
    # setup quotes into literal backslash-quotes inside the command payload.
    result = subprocess.run('cmd.exe /d /s /c "' + command + '"', cwd=output,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'native-build.log').write_text(result.stdout, encoding='utf-8')
    if result.returncode:
        print(result.stdout)
        raise SystemExit(result.returncode)
    dll = output / 'BridgeCombatNative.dll'
    provenance = sources + [native / name for name in ('core.h', 'mode.h', 'actor.h')]
    receipt = {'artifact': str(dll), 'sha256': hashlib.sha256(dll.read_bytes()).hexdigest(),
               'game_timestamp': '6AB3B43F', 'exe_timestamp': '6AB382E4',
               'state': 'compiled review helper; not installed or loaded',
               'source_sha256': {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                                 for path in provenance}}
    (output / 'native-build-receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps({'artifact': str(dll), 'sha256': receipt['sha256'], 'compiled': True}))


if __name__ == '__main__':
    main()
