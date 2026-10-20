# Unreleased Content

An experimental LLL mini-mod that adds the game's existing LAS-22 Shear to
Armory > Primary > Energy-Based without replacing another weapon.

Requires LLL folder-project support and game.dll timestamp `6AB3B43F`.
Install the ZIP's `goose_unreleased_content` folder under
`%LOCALAPPDATA%/LLL/Helldivers2/Mods`. Close the Armory during activation.

The mod registers one native inventory root and initializes missing per-weapon
customization state using the Shear's own attachment defaults for all three
presets. It does not grant additional attachment options. Existing Shear
inventory or customization records remain owned by their current provider.

Registration runs once. When the catalogue is not ready, initialization retries
once per second for at most 60 attempts, then stops. After registration the update
callback does no memory I/O. If the game rebuilds its inventory later in the same
session, close the Armory and disable/re-enable the mod.

Disable with the Armory closed and another primary selected. Cleanup restores
only bytes still matching this mod's acknowledged writes. It waits when the Shear
is equipped, another writer changes those bytes, or ownership cannot be verified.
Changes made through the customization screen may require retaining the mod
until the game closes. No native game function, purchase, currency or save API is
called by this mod. The inventory and customization structures are save-backed;
the game may persist their contents independently. Persistence is not tested.

## Validation

The maintained feature now lives in **Temporary Unlocks > Unlock unreleased
weapons**. Disable this standalone prototype when using that option. The native
Edit gate was observed working. The integrated candidate additionally registers
native-hashed attachment children, default grants and progression state; final
attachment-screen visual validation is pending.

The Shear was observed in the running game's Armory with its native model,
description, statistics and Equip button. Initial registration, the transition
into the Armory, and loaded-file hashes were verified. Shooting, multiplayer,
restart persistence and attachment compatibility are separate tests.

Offline fixtures cover category/index consistency, existing-record refusal,
publication ordering, partial-write rollback, cleanup ownership, native preset
initialization, bounded startup retries and idle steady state.

Run `py -3 tests/run_tests.py`, then `py -3 tools/build.py`.
Packages contain only the fixed source/documentation allowlist; private captures,
diagnostics, installed game files and retained native-code dumps are excluded.

## Implementation evidence

Native weapon catalogue row 42 identifies primary `0x7DE53646`, entity resource
`7e3145a5baa4b948`. Initial live inspection found that entry in the weapon
catalogue and absent from the inventory catalogue. The mod reconstructs the
record/index layout from native constructor `game+136EC00` and category ordering
from `game+136E6A0`. Per-weapon preset initialization follows
`game+1034BD0..1034D60`, joined to the Shear's `WeaponCustomizationComponentData`.
Current function fingerprints, component framing, exact resource identity,
record bounds and ownership are checked before writes.

Private evidence and deployment receipts are retained under ignored `dist/`.
