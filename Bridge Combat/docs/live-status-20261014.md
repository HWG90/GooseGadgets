# Bridge Combat stopping point, October 14

User stopped testing for the night after the native whole-scene mode switch crashed. Do not restart or rerun automatically.

The separate Height Over Bore release remains published and untouched. Installed Bridge Combat remains the original control-only 0.1 files; all new work is review/prototype source.

## Live results

- Exact clip references: batch584 acquired all15 current animation clips from1 to2 through ordinary six-argument ResourceManager requests and acknowledged balanced nonfinal release back to1. The animation finalizer callback was uniquely null. No borrowed package was loaded/unloaded.
- Batch585 changed the normal body layers to67/10/6 once, with owned clip/weapon references and temporary MCM controls. Batch586 still showed all3 mission states59seconds later. Cleanup acknowledged at01:53:44, before the90second timer, so an earlier stop condition ended it. No exact stop reason was recorded in that driver version.
- User reported briefly correct grip/arms, followed by a stiff upper body and abnormal running swings; final answer still wrong arms/bridge idles. This is partial visual progress, not full normal diver behavior.
- Rerun initially refused because layer4 was already at authored state67. Dynamic capture now saves the actual current authored state, leases its old/target clip union and skips layers already at target. Batch589 ran the five-minute test from layer4=67, layer21=1, layer22=1. Subsequent cleanup left no body task active by batch590.
- Ship HUD suppression source and fixture are ready; private standalone review DLL built/PE-validated but NOT loaded or installed. It is distinct from full MissionHUD/health.
- Mode-only wrapper source was prepared but not used for the crash. Its offline fixture work was interrupted when user stopped.
- The crash test directly called fingerprinted game.dll+AB2FA0 as void(GameState*,uint32,void*) with requested scene4 and null optional context. A60second ordinary mode3 rollback was registered beforehand; the process crash prevented runtime cleanup. There was no direct AD4520 completion call or phase-byte forcing. Exact final command/call log and results are saved beside this note. Verify the captured call log before claiming how far entry progressed.

## Current evidence boundaries

No full mission HUD, health/damage, normal locomotion, stable Armory swap or session/death lifecycle is proven. No production Bridge Combat package was installed/published. The reported crashed process may remain listed under Windows crash handling. Its prototype owners retire when it closes; no native rollback is acknowledged. The owned batch593 command has been neutralized to prevent startup replay.

## Next morning

Start by reading saved crash details/call log and checking fresh process/build/state. Diagnose native mode entry failure before repeating it. Relevant source contracts: clip-resource-lease-contract-20261014.md; mission-hud-lease-contract-20261014.md; ship-hud-suppression-lease-20261014.md. The normal existing-player hellpod-exit animation signal is243FEC95 (game932AC0 -> EXE201900), distinct from whole-mode AB2FA0 and PlayerCtor81BE70. Its full transition/clip scope remains unproved. User explicitly authorized trying whole ship mission mode, but stopped for tonight.
