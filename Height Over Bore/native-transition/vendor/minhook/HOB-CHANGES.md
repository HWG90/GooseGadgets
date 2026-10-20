# Local MinHook change

Based on the supplied MinHook 1.3.4 source identified in PROVENANCE.json.
The upstream files were copied locally; no dependency was fetched or updated.

In src/hook.c, x64 hook creation uses the detour directly when its rel32 jump
fits. Otherwise it retains the upstream relay behavior. The native queue commit
thunks are deliberately allocated above and within 2 GiB of the game image.
They provide Windows unwind records for the native frame, synthetic return and
saved callback frame. An intermediate relay with no corresponding native-frame
unwind description would break that contract.

The upstream license and provenance remain alongside this note. The original
provenance scope describes the imported baseline; this note records the change.
