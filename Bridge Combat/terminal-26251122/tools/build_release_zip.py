"""Pack goose_bridge_combat/ into dist/releases/ as the LLL download, with its checksum file.

The package is taken as it is (the assembled, receipt-listed tree); nothing is rebuilt here. The manifest's
native entry must name the one DLL in the tree and match its SHA-256, and every file must be in the receipt
with the same hash, so the archive holds exactly the tree that was verified.

Usage: python3 -I build_release_zip.py [--output DIR]   (from the terminal-26251122 folder or anywhere)
"""
import argparse, hashlib, json, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
PACKAGE = HERE / 'goose_bridge_combat'
RECEIPT = HERE / 'goose_bridge_combat-RECEIPT.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=HERE / 'dist/releases')
    args = parser.parse_args()
    manifest = json.loads((PACKAGE / 'manifest.json').read_text(encoding='utf-8'))
    receipt = json.loads(RECEIPT.read_text(encoding='utf-8'))
    assert manifest['id'] == 'goose_bridge_combat' and manifest['version'] == receipt['version'], 'manifest and receipt versions differ'
    files = {p.relative_to(PACKAGE).as_posix(): p.read_bytes() for p in sorted(PACKAGE.rglob('*')) if p.is_file()}
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
    assert hashes == receipt['files'], 'package files differ from the receipt: %s' % sorted(set(hashes) ^ set(receipt['files']))
    dlls = [name for name in files if name.endswith('.dll')]
    native = manifest['native']
    assert dlls == [native['file']] and hashes[native['file']] == native['sha256'], 'native entry differs from the DLL in the tree'
    assert set(manifest['lll']['modules']) == {name for name in files if name.startswith('src/')}, 'module allowlist differs'
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / ('BridgeCombat-%s-LLL.zip' % manifest['version'])
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            entry = zipfile.ZipInfo(manifest['id'] + '/' + name, (2026, 10, 30, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            z.writestr(entry, data)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.output / 'RELEASE-SHA256SUMS.txt').write_text(digest + '  ' + archive.name + '\n', encoding='ascii')
    (args.output / 'build-manifest.json').write_text(json.dumps(
        {'id': manifest['id'], 'version': manifest['version'], 'archive': archive.name, 'sha256': digest, 'files': hashes,
         'native': native, 'state': 'packed from the receipt-listed tree; deployed and observed gameplay are separate evidence'},
        indent=2) + '\n', encoding='utf-8')
    print(archive, archive.stat().st_size, 'bytes', digest)


if __name__ == '__main__':
    main()
