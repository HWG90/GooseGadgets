"""Stage an allowlisted native review package. Never installs or starts the game."""
from pathlib import Path
import hashlib
import json
import zipfile
ROOT=Path(__file__).resolve().parent
BASE=ROOT.parent/'dist'/'releases'
OUT=BASE/'hob-v0.1.3-native-review.2-lll'
OUT.mkdir(parents=True,exist_ok=True)
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
provider=json.loads((BASE/'hob-native-transition-offline'/'verification.json').read_text())
assert len(provider['fixture_results'])==16 and all(x.startswith('PASS ') for x in provider['fixture_results'])
for name,value in provider['source_sha256'].items():assert digest(ROOT/name)==value, 'Native evidence stale: '+name
loader=json.loads((BASE/'hob-native-loader-fixture'/'verification.json').read_text())
assert loader['tests']=='passed'
for name,value in loader['source_sha256'].items():assert digest(ROOT/name)==value, 'Loader evidence stale: '+name
guard=json.loads((BASE/'hob-native-transition-guard-fixture'/'verification.json').read_text())
assert guard['game_image_executed'] is False
for name,value in guard['source_sha256'].items():assert digest(ROOT/name)==value, 'Admission evidence stale: '+name
library=Path(provider['review_artifact'])
assert digest(library)==provider['review_sha256']
manifest=json.loads((ROOT/'lll/manifest.json').read_text())
assert manifest['id']=='goose_hob_native_review' and manifest['version']=='0.1.3-native-review.2'
assert set(manifest['lll']['modules'])=={'native.lua','lifecycle.lua'}
payload={name:(ROOT/'lll'/name).read_bytes() for name in ['main.lua','native.lua','lifecycle.lua','manifest.json']}
payload['hob_transition_live_review.dll']=library.read_bytes()
payload['LICENSE']=(ROOT.parent/'ads-prototype/LICENSE').read_bytes()
payload['REVIEW.md']=b"""# Height Over Bore native review 0.1.3-native-review.2

Not a public release. Not installed by this builder. Start with HoB disabled.
Enable DBF-MCM first. Disable the existing HoB mod before enabling this review.
The new MCM registration is Height Over Bore Native Review; its default is off.

Native events provide camera entry/exit, equip/unwield, component lifetime and
shutdown. No frame callback, timer, worker or polling consumer is registered.
Selected-weapon setup occurs once per equip. Projectile ADS uses the accepted
0.5-degree correction limit; hip fire, third-person and beams retain native values.
This does not establish exact historical Arrowhead geometry.

Offline proof: 16 provider/integration scenarios, consumer memory fixtures,
LuaJIT lifecycle/FFI tests and build-specific native admission guards.
Live coverage, thread affinity, before-firing order, overhead and spikes remain
unverified. Deployment requires separate approval. No GameGuard changes exist.

Disable restores native values before detachment. Incomplete cleanup retains
recovery state and reports failure; use explicit cleanup retry. Do not unload a
helper with pending restoration. Clean re-enable reuses retained native code.
The helper and unwind/trampoline storage remain pinned for process lifetime.

Live review sequence after approval: disabled observer transitions; verify
thread/failure counters; test projectile ADS close/distant and native hip/third
person; forced exits, equip/unequip, death/respawn, disable/re-enable; then measure
steady state and transition costs. Stop on rejection or failure, without bypassing
admission guards or GameGuard.
"""
folder=OUT/manifest['id']
if folder.exists():
    for p in folder.rglob('*'):
        if p.is_file():assert p.relative_to(folder).as_posix() in payload, 'Unexpected staged file'
for name,data in payload.items():
    target=folder/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
    assert target.read_bytes()==data
archive=OUT/'hob-v0.1.3-native-review.2-lll.zip'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
    for name,data in sorted(payload.items()):z.writestr(manifest['id']+'/'+name,data)
with zipfile.ZipFile(archive) as z:
    assert set(z.namelist())=={manifest['id']+'/'+name for name in payload}
    for name,data in payload.items():assert z.read(manifest['id']+'/'+name)==data
receipt={'archive':str(archive),'sha256':digest(archive),'payload_sha256':{n:hashlib.sha256(v).hexdigest() for n,v in payload.items()},'installed':False,'live_verified':False,'native_scenarios':16,'loader_tests':'passed','activation':'guarded review only; off by default'}
(OUT/'verification.json').write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({k:receipt[k] for k in ['archive','sha256','installed','live_verified']},indent=2))
