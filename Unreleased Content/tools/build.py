"""Build the fixed LLL package allowlist. Never install or publish anything."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ('main.lua', 'manifest.json', 'config/defaults.cfg', 'src/catalogue.lua',
         'src/backend.lua', 'src/memory.lua', 'src/customization.lua', 'src/group.lua', 'README.md', 'LICENSE')


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    assert manifest['id'] == 'goose_unreleased_content'
    assert set(manifest['lll']['modules']) == {n for n in FILES if n.startswith('src/')}
    folder = ROOT / 'dist/releases'
    folder.mkdir(parents=True, exist_ok=True)
    output = folder / ('Unreleased-Content-' + manifest['version'] + '-LLL.zip')
    hashes = {}
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as package:
        for name in FILES:
            data = (ROOT / name).read_bytes()
            if name.endswith('.lua'):
                assert not data.startswith((b'\xef\xbb\xbf', b'\x1b')) and b'\0' not in data
                data.decode('utf-8')
            hashes[name] = hashlib.sha256(data).hexdigest()
            item = zipfile.ZipInfo('goose_unreleased_content/' + name, (1980, 1, 1, 0, 0, 0))
            item.compress_type = zipfile.ZIP_DEFLATED
            package.writestr(item, data)
    with zipfile.ZipFile(output) as package:
        assert package.testzip() is None
        assert set(package.namelist()) == {'goose_unreleased_content/' + n for n in FILES}
        for name in FILES:
            assert package.read('goose_unreleased_content/' + name) == (ROOT / name).read_bytes()
    receipt = {'archive': output.name, 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'files': hashes}
    output.with_suffix('.json').write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    print(output)
    print(receipt['sha256'])


if __name__ == '__main__':
    main()
