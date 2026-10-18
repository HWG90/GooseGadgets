"""Package independent Bridge Combat only; no MCM or loader is bundled."""
from pathlib import Path
import argparse,json,zipfile
import build_bsl as b

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--addon',type=Path,default=b.ROOT/'dist/releases/bridge-combat-0.1.15-experimental-bsl-review');p.add_argument('--output',type=Path,required=True);a=p.parse_args()
 source=a.addon/'BridgeCombat-0.1.15-experimental-BSL.zip';raw=source.read_bytes()
 with zipfile.ZipFile(source)as z:
  assert set(z.namelist())==set(b.PACKAGE_FILES)and z.testzip()is None
  resources=b.lua_archive.read(z.read('Addon/'+b.ARCHIVE));assert len(resources)==1 and b.lua_archive.hash_name(b.ENTRY)in resources
 a.output.mkdir(parents=True,exist_ok=True);target=a.output/'BridgeCombat-0.1.15-BSL-Standalone.zip';target.write_bytes(raw);digest=b.sha256(raw)
 (a.output/'SHA256SUMS.txt').write_text(digest+'  '+target.name+'\n')
 (a.output/'build-manifest.json').write_text(json.dumps({'archive':target.name,'sha256':digest,'resources':1,'bundled_loader':False,'bundled_mcm':False,'validation':'Offline allowlist, ZIP integrity and startup resource identity verified'},indent=2))
 print(target);print('PASS standalone payload: no loader or MCM resources')
if __name__=='__main__':main()
