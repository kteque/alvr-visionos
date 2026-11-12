Repository Guidelines

## Project Structure & Module Organization
- `ALVRClient/` contains the visionOS client sources (Swift, Metal shaders, assets).
- `ALVREyeBroadcast/` contains the ReplayKit extension sources.
- `ALVR/` holds upstream ALVR components and samples.
- Xcode project: `ALVRClient.xcodeproj`.
- Configs and build scripts live at the repo root (`*.xcconfig`, `build_and_repack.sh`).

## Build, Test, and Development Commands
- Build the client (no simulator launch):
  `xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -configuration Debug build`
- Optional release build:
  `xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -configuration Release build`
- There is no standard test target in this repo; rely on build + device testing.

## Coding Style & Naming Conventions
- Swift: 4‑space indentation, Swift API Design Guidelines, `camelCase` for variables/functions, `PascalCase` for types.
- Metal: keep shaders in `ALVRClient/Shaders.metal`, follow existing naming (e.g., `hudVertexShader`).
- Prefer small, self‑contained helpers and keep tunables near the top of files.

## Testing Guidelines
- No automated test suite is defined.
- Validate by building and, when applicable, device testing on visionOS hardware.

## Commit & Pull Request Guidelines
- Commit subjects in recent history use short prefixes like `fix:`, `perf:`, and `WIP`; follow that pattern when appropriate.
- Keep commits focused; include a short description of user‑visible changes in PRs.
- If UI changes are made, include screenshots or a brief description in the PR.

## Agent-Specific Instructions
- After code changes, run an Xcode build (no simulator) before finalizing:
  `xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -configuration Debug -destination 'generic/platform=visionOS' build`
- If the build fails, fix it or report the failure with the error summary.

## AirFrameXR fork notes (2026-10-29)
- Branches: `airframexr-client` is the released client (tags `v1.2.0`...); `calibration` is the same app with no field-of-view ceiling
  (`GlobalSettings.visibleFovTangents` returns 10.0), kept for the sweep sessions and rebased on the client's fixes; `main` tracks upstream.
  Versions are numbered with the AirFrameXR streamer release they pair with (`README.md`, the TestFlight workflow's default `marketing_version`).
- The calibration data (the wearer's rectangle) lives on the PC, never in this app: this app only declares a per-edge ceiling. Do not add
  field-of-view sliders or presets here; change the ceiling constants only when a measured wearer exceeds them (AirFrameXR
  `docs/FOV_CLIENT_CEILING.md`).
- No hand input: hands never reach the game (no pinch, no hand-as-controller pose, no skeleton, since 1.3.1; users got random commands
  from the pinch). Do not bring it back. ARKit's `HandTrackingProvider` stays running only so the Steam Controller pose can be fused from the
  hands holding it. Debug lines go to the streamer's log through `alvr_log` (`[home]`, `[stream]` tags; `[floor]` is no longer sent: the Entry window has the value); remove them before a release.
- Chroma key: with a key on, the render pass clears transparent and `videoFrameBorderVertexShader` draws a ring around the declared frame whose
  alpha is the key mask of the frame's edge texel (black where the edge is picture, transparent where it is the key colour); without a key the
  clear is opaque black and no ring is drawn. Keyed pixels are written as premultiplied zero (the video pipeline does not blend); never bring
  back `discard_fragment()` for them (it leaves the clear colour in place).
- Cross-repository: the client's behaviour is documented in the AirFrameXR repository (`docs/AVP_FOV.md`, `docs/FOV_CALIBRATION.md`,
  `docs/FOV_CLIENT_CEILING.md`, `docs/FOV_GRID.md`); this README carries the summary and the release list.
- Signing: every TestFlight run mints a certificate; on "maximum number of certificates" run the workflow with the revoke input ticked
  (`docs/TESTFLIGHT.md`).
- Protocol harness (`tools/protocol-harness/README.md`): the real `EventHandler.swift` on Linux against a scripted streamer
  and a render-loop model (`build.sh`, `run.sh [--tsan]`). Run it after any change to the event loop, `handleNals`, decoder
  lifecycle or the render thread's frame pick; keep `Harness/DisplaySim.swift` in step with `Renderer.renderFrame`.
- Shared stream state (decoder session + format + config bytes, frame queue, last shown frame, last submitted timestamp) is
  read and written under `frameQueueLock` only; the render thread goes through `pollFrameForDisplay` / `publishShownFrame` /
  `markSubmitted`. `[stream]` lines (`EventHandler.streamLog`) are rare transition events for the streamer's log, not per frame.
- client_core changes are carried as patches on the ALVR submodule (`patches/*.patch`, applied by `scripts/apply_core_patches.sh`
  from `build_and_repack.sh` and both workflows), not as a fork of ALVR. Keep each one small and say why in the patch itself.
