# Armory checkpoint — 2026-10-18

The current release is the 0.1.14 terminal line, separate from the superseded 0.2 actor-route prototype. The LLL and BSL ZIPs contain the same allowlisted runtime modules. Neither bundles a loader. MCM is optional.

## Gameplay

The fixed Armory cabinet has a 7 × 5 charcoal/gold icon grid, wrapped labels, mousewheel scrolling, native Interact-action exit, confined arrow cursor and a framing camera. WEAPONS FREE toggles combat, including when a support weapon is requested. Direct inventory delivery supplies authored attachments and the matching backpack; replacement removes old support gear while preserving primary and sidearm loadouts. Combat Off removes terminal gear and restores ship animations and carried attachments.

Native health/stamina, moving crosshair, weapon quick actions, chat, hidden name/XP, emote-wheel visibility and zoom-change audio have live evidence. Recoilless effects survived an area return. Melee replacement and combat-Off teardown were confirmed normal. The no-MCM BSL terminal, input, scrolling, combat toggle, inventory request and camera restoration were confirmed in gameplay before the newest shared loading changes.

## Asset loading

On normal, focused ship entry, the station's existing lifecycle probe starts shared UI/FX/audio warmup without enabling combat. A retained loading bar shows the current stage and disappears on readiness acknowledgement. It redraws only when the stage changes. New bridge sessions reacquire and revalidate owners. Menus and Photo Mode can defer guarded loading.

The old live request timeline showed UI material/atlas requests at 29.159 / 30.840 seconds of the process clock; FX/audio requests at 29.160, 30.847, 45.793, 60.916 and 76.089. Independent jobs waited behind earlier providers, and exponential backoff reached 15 seconds. The final FX request started 46.929 seconds after the first. No old total-load duration was recorded.

The updated loader submits all five independent FX/audio providers and both UI providers without waiting for preceding providers to finish. Accepted native requests never repeat. Normal completion discovery is bounded to 4 Hz only while loading. Ambiguous calls pin their journals; module/actor/ownership safeguards and native-cleanup gates remain. Error paths retain conservative backoff. No disk-cache flush, extra asset unload or smaller dependency set was used for the comparison.

Fresh-process LLL readback:

| Group | Verification elapsed | Total measured Lua/native-call CPU | Largest measured update | Loading passes |
| --- | --- | --- | --- | --- |
| UI materials/atlas/native bases | 1.107 s | 32 ms | 22 ms | 4 |
| Shared FX, external textures and mission UI audio | 1.635 s | 17 ms | 13 ms | 6 |

All provider request timestamps were within approximately 1 ms of their group's start. The remaining one-time setup/verification peaks are documented; this is not a hitch-free startup claim. These are loader-stage measurements, not launch-to-ship time, GPU cost, or a controlled disk-cache benchmark. The old request spread and new readiness times are different metrics and must not be described as a measured 47-to-1.64-second total-load speedup.

After the faster load, the user confirmed the terminal, combat toggle, weapons/effects, HUD and chat were normal. Settled combat with the terminal closed measured **10.906 ms/s** combined update and terminal render at approximately 116 frames/s over five seconds. UI/FX loader update calls were both zero in that sample. Earlier matched measurements were 11.322 ms/s before the idle optimization and 10.959 ms/s after it; this small latest difference is not a separately established steady-state speedup.

## Checks and unresolved work

Focused lifecycle, input, exact asset readiness, recovery, cleanup and package fixtures pass. Added tests verify concurrent provider submission, acknowledgement within the bounded completion interval, no repeated accepted requests, no per-frame loading discovery and idle Ready state. The accepted native helper retains its 117 isolated lifetime cases. BSL startup compilation and both archive variants are checked with explicit payload allowlists and byte/round-trip integrity. Final loading timings and the newest gameplay confirmation are LLL evidence; BSL is not claimed to have an equivalent final timing run.

Cabinet collision and native weapon holstering during emotes remain unfinished. A temporary environmental collision body blocked movement but retained its large authored collision bounds and emitted unwanted fog; it was immediately destroyed and its absence verified. Changing its visual scale did not resize collision. That test body is not included in source packages or release downloads. A pure cabinet-sized static box still requires a verified native creation and retirement route.

The repository and release archives contain no user settings, game captures, game assets or private diagnostic files. Local deployment backups preserve settings separately.
