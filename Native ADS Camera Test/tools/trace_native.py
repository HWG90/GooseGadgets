"""Reproduce the native ADS camera trace from an explicitly supplied offline dump.

The input must be a memory-layout game.dll image: file offset equals RVA.
This tool never attaches to a process and never copies the dump into its outputs.
Requires Python 3 and capstone. Output: this gadget's dist/research directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

from capstone import CS_ARCH_X86, CS_MODE_64, Cs


ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "src" / "profile.lua"
OUTPUT = ROOT / "dist" / "research"

# Bounded excerpts contain only the camera paths needed for this experiment.
EXCERPTS = (
    ("enter-wrapper", 0x127DDB0, 0x127DE1C),
    ("enter-constructor-guards", 0x127DE20, 0x127DF35),
    ("enter-presentation", 0x127E01B, 0x127E486),
    ("enter-enqueue", 0x127E85B, 0x127E970),
    ("exit-guards", 0x127E9D0, 0x127EAA0),
    ("exit-fallback-enqueue", 0x12805EF, 0x1280710),
    ("kind6-dispatch", 0x1279611, 0x1279661),
    ("evaluator-guards", 0x1286330, 0x1286430),
    ("controller-enter", 0x12B29B0, 0x12B2AD5),
    ("controller-exit", 0x12B2AE0, 0x12B2B31),
    ("controller-aim-gate", 0x12B288F, 0x12B28ED),
    ("input-desired-gate", 0xA41C0B, 0xA41C51),
    ("weapon-eligibility", 0x12B2D20, 0x12B2E14),
    ("reset-exit-91d250", 0x91D108, 0x91D262),
    ("transition-exit-adc691", 0xADC658, 0xADC769),
)

# Expected direct E8 callsites. These are checked, not inferred from strings.
CALLS = (
    ("direct_enter_to_constructor", 0x127DDC0, 0x127DE20),
    ("direct_enter_to_evaluator_dt0", 0x127DDF8, 0x1286330),
    ("frame_kind6_to_evaluator", 0x1279643, 0x1286330),
    ("controller_enter_to_eligibility", 0x12B29DC, 0x12B2D20),
    ("controller_enter_to_constructor", 0x12B2A3E, 0x127DE20),
    ("controller_enter_to_evaluator", 0x12B2A76, 0x1286330),
    ("controller_aim_gate_to_exit_wrapper", 0x12B28C7, 0x12B2AE0),
    ("controller_exit_to_native_exit", 0x12B2AF5, 0x127E9D0),
    ("input_enter", 0xA41C25, 0x12B29B0),
    ("input_exit", 0xA41C33, 0x12B2AE0),
    ("actor_reset_exit", 0x91D250, 0x127E9D0),
    ("pose_transition_exit", 0xADC691, 0x127E9D0),
    ("invalid_actor_exit", 0x12863E1, 0x127E9D0),
    ("native_exit_to_frame_evaluator", 0x12806F7, 0x1279190),
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def parse_profile() -> tuple[int, int, list[dict]]:
    source = PROFILE.read_text(encoding="utf-8")

    def number(name: str) -> int:
        match = re.search(r"\b" + re.escape(name) + r"\s*=\s*(0x[0-9A-Fa-f]+)", source)
        require(match is not None, f"Missing profile {name}")
        return int(match.group(1), 16)

    checks = [
        {"name": name, "rva": int(rva, 16), "hex": encoded}
        for name, rva, encoded in re.findall(
            r'\{name\s*=\s*"([a-z0-9_]+)",\s*rva\s*=\s*(0x[0-9A-Fa-f]+),'
            r'\s*hex\s*=\s*"([0-9a-f]+)"\}', source
        )
    ]
    require(len(checks) >= 11, "Profile signature table is incomplete")
    return number("timestamp"), number("image_size"), checks


def pe_identity(image: bytes) -> tuple[int, int]:
    require(len(image) >= 0x100, "Truncated PE image")
    require(image[:2] == b"MZ", "Input is not a PE image")
    pe = struct.unpack_from("<I", image, 0x3C)[0]
    require(0 <= pe <= len(image) - 0x100, "Invalid PE header offset")
    require(image[pe : pe + 4] == b"PE\0\0", "Invalid PE signature")
    require(struct.unpack_from("<H", image, pe + 4)[0] == 0x8664, "Expected x64 image")
    require(struct.unpack_from("<H", image, pe + 24)[0] == 0x20B, "Expected PE32+")
    return (
        struct.unpack_from("<I", image, pe + 8)[0],
        struct.unpack_from("<I", image, pe + 24 + 56)[0],
    )


def bounded(image: bytes, rva: int, size: int) -> bytes:
    require(rva >= 0 and size > 0 and rva + size <= len(image), "RVA outside supplied image")
    return image[rva : rva + size]


def direct_call(image: bytes, site: int, expected: int) -> dict:
    code = bounded(image, site, 5)
    require(code[0] == 0xE8, f"Expected direct call at RVA {site:X}")
    target = site + 5 + struct.unpack_from("<i", code, 1)[0]
    require(target == expected, f"Call target changed at RVA {site:X}")
    return {"site_rva": f"0x{site:X}", "target_rva": f"0x{target:X}"}


def disassemble(image: bytes, start: int, end: int) -> str:
    md = Cs(CS_ARCH_X86, CS_MODE_64)
    lines = []
    for instruction in md.disasm(bounded(image, start, end - start), start):
        note = ""
        match = re.search(r"\[rip ([+-]) (0x[0-9a-f]+)\]", instruction.op_str)
        if match:
            displacement = int(match.group(2), 16) * (1 if match.group(1) == "+" else -1)
            target = instruction.address + instruction.size + displacement
            note = f" ; RIP target RVA {target:08X}"
        lines.append(
            f"{instruction.address:08X}  {instruction.mnemonic:<8} {instruction.op_str}{note}"
        )
    require(lines, f"No instructions decoded at RVA {start:X}")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dump", type=Path, required=True, help="Existing memory-layout game.dll dump")
    args = parser.parse_args()
    image = args.dump.read_bytes()
    expected_stamp, expected_size, checks = parse_profile()
    stamp, size = pe_identity(image)
    require(stamp == expected_stamp, "Unsupported game timestamp")
    require(size == expected_size, "Unsupported PE SizeOfImage")
    require(len(image) == size, "Expected one complete memory-layout image, not the packed disk DLL")
    for check in checks:
        expected = bytes.fromhex(check["hex"])
        actual = bounded(image, check["rva"], len(expected))
        require(actual == expected, f"Signature mismatch: {check['name']} at RVA {check['rva']:X}")

    relationships = {name: direct_call(image, site, target) for name, site, target in CALLS}
    dispatch = struct.unpack_from("<I", image, 0x127A3B8 + 5 * 4)[0]
    require(dispatch == 0x1279639, "Native type-6 dispatch changed")
    report = {
        "status": "offline_verified",
        "input": {"name": args.dump.name, "sha256": hashlib.sha256(image).hexdigest()},
        "pe_timestamp": f"0x{stamp:X}",
        "pe_size_of_image": f"0x{size:X}",
        "profile_sha256": hashlib.sha256(PROFILE.read_bytes()).hexdigest(),
        "signature_checks": [{"name": c["name"], "rva": f"0x{c['rva']:X}", "bytes": len(c["hex"]) // 2} for c in checks],
        "direct_calls": relationships,
        "type6_dispatch": {"table_rva": "0x127A3B8", "index": 5, "branch_rva": f"0x{dispatch:X}", "evaluator_rva": "0x1286330"},
        "camera_request": {"head_offset": "0x1F8", "tail_offset": "0x1FC", "ring_offset": "0x200", "stride": "0xE8", "capacity": 32, "fallback_offset": "0x1F00", "avatar_offset": 4, "weapon_offset": 8},
        "proven": [
            "Native entry constructs a full type-6 request from current type 4; it does not freeze a stored pose.",
            "Ordinary FPV controller active byte +4 is separate from native camera request type.",
            "Input skips enter/exit when desired AL equals controller +4.",
            "Controller update tests actor packed-state bit 48 and calls the ordinary exit wrapper when absent.",
            "Ordinary exit wrapper calls the native exit helper only while controller +4 is set.",
            "The lower native entry path has no direct store to the known aiming qword or ordinary controller +4.",
            "Native entry performs visibility, unit-property, DOF, event and attachment setup; native exit reverses presentation and enqueues a fallback.",
        ],
        "unknown": [
            "Complete neutrality of indirect native presentation and animation callees.",
            "Whether camera kind 6 persists and behaves correctly while gameplay aiming remains false.",
            "Live firing, movement, reload, weapon switch, scope, vehicle, death and respawn behavior.",
            "Any compatibility with another mod that owns camera or native first-person presentation.",
        ],
        "live_test_performed": False,
        "game_process_accessed": False,
    }
    # Validate everything before creating any report or disassembly outputs.
    excerpts = {name + ".txt": disassemble(image, start, end) for name, start, end in EXCERPTS}
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for name, content in excerpts.items():
        (OUTPUT / name).write_text(content, encoding="utf-8")
    (OUTPUT / "native-trace.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"Verified {len(checks)} signatures, {len(CALLS)} direct calls and type-6 dispatch.")
    print(f"Saved {len(excerpts)} bounded disassemblies and native-trace.json to {OUTPUT}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, struct.error) as error:
        raise SystemExit(f"Trace failed: {error}") from error
