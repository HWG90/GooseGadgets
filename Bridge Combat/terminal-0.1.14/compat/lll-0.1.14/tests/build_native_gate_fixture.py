"""Negative package gates only. No file writes, native library load or game."""
from pathlib import Path
from unittest.mock import patch
import hashlib
import json
import runpy

here = Path(__file__).resolve().parent
build = runpy.run_path(str(here.parent / 'build.py'))
read_native = build['native_payload']
payload = b'fixture bytes, never a native library'
digest = hashlib.sha256(payload).hexdigest()
base = {'persistent_lifetime_proof_accepted': True,
        'afk_dirty_retirement_proof_accepted': True,
        'ship_active_cleanup_proof_accepted': True,
        'drop_widget_constructor_prerequisite_proof_accepted': True,
        'drop_detached_primitive_lifetime_proof_accepted': True,
        'supported_game_stamp': '0x6AB3B43F', 'supported_exe_stamp': '0x6AB382E4',
        'dll': str(here / ('BridgeCombatWeaponMenu-' + digest[:12] + '.dll')),
        'dll_sha256': digest, 'exports': build['EXPORTS']}

def refuses(changes):
    receipt = {**base, **changes}
    def read(path):
        return json.dumps(receipt).encode() if path.name == 'receipt.json' else payload
    with patch.object(Path, 'read_bytes', read), patch.object(Path, 'write_bytes') as write:
        try:
            read_native(here / 'receipt.json')
        except (AssertionError, ValueError, KeyError):
            assert not write.called
            return
        raise AssertionError('Invalid native proof/binary was accepted')

for changes in (
    {'persistent_lifetime_proof_accepted': False},
    {'persistent_lifetime_proof_accepted': None},
    {'afk_dirty_retirement_proof_accepted': False},
    {'ship_active_cleanup_proof_accepted': False},
    {'drop_widget_constructor_prerequisite_proof_accepted': False},
    {'drop_detached_primitive_lifetime_proof_accepted': False},
    {'supported_game_stamp': '0x00000000'},
    {'supported_exe_stamp': '0x00000000'},
    {'dll_sha256': '0' * 64},
    {'dll': str(here / 'BridgeCombatWeaponUiReview-f48a493f4005.dll')},
    {'exports': ['BC_weapon_ui_start']},
    {},  # exact receipt assertions cannot make non-PE bytes executable
):
    refuses(changes)
print('PASS 12 native package refusal gates; no binary bundled or file written')
