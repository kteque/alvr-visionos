# AirFrameXR client for Apple Vision Pro

The visionOS client of [AirFrameXR](https://github.com/jfbobier/AirFrameXR), wireless PC VR for NVIDIA cards: the
PC runs the game through AirFrameXR's OpenXR runtime (frame generation, foveated encoding, NVENC), streams it with
the ALVR v20 protocol, and this app shows it on the Vision Pro with hand and PlayStation VR2 Sense controller
tracking.

Version 1.2.2 (numbered with the AirFrameXR streamer it pairs with). Nearly feature complete; what is left is listed at the end.

## Credits

This app is a fork of [ALVR for Apple visionOS](https://github.com/alvr-org/alvr-visionos), written by
[Max Thomas (shinyquagsire23)](https://github.com/shinyquagsire23) and the alvr-org contributors, among them
panthurrr, zhuowei, shadowfacts, dereklucas, sidd, jfenton, svrc and robbiet480. The renderer, the tracking, the
ALVR client core integration, the controller and hand input, the chroma key and the TestFlight-ready project are
theirs. The streaming protocol and the client core are [ALVR](https://github.com/alvr-org/ALVR). Both are MIT
licensed and so is this fork (see `LICENSE`).

## What this fork adds

Everything below is in the `airframexr-client` branch on top of upstream `main`.

**Picture**

- Metal renderer only. The RealityKit renderer and its options are removed, so there is one code path to tune.
- Field of view: the app declares a per-edge **ceiling** to the streamer (outer / inner / up / down tangents
  1.03 / 0.79 / 0.75 / 0.86, about 1.05 / 0.80 / 0.76 / 0.87 once the canted views are circumscribed), a generous
  box that covers the wearers measured so far with a margin. The wearer's own rectangle is set on the PC (the
  streamer's Advanced window, or the Vision Pro profile the wizard applies: 0.97 / 0.71 / 0.69 / 0.63 in 1.2.0),
  never on the headset; the streamer can only go down from the ceiling. Measurement and numbers:
  `docs/AVP_FOV.md`, `docs/FOV_CALIBRATION.md` and `docs/FOV_CLIENT_CEILING.md` in the AirFrameXR repository.
  The `calibration` branch is the same app with no ceiling at all, for the field-of-view sweep sessions.
- The chroma key is taken from the streamer's settings (`video.passthrough`), so the key colour and distance are
  set once, on the PC. Keyed pixels are written transparent and everything the frame does not cover is black:
  you see the room between games (the streamer's idle colour) and around the desktop mirror's screen (its
  background is that colour), never past the frame's edge, and a game, which paints its own picture, is opaque.

**Space**

- Floor height: the height the headset reports is shown live in the window, with a manual offset (plus or minus
  50 cm) that is added to it. The sum is what the game sees as your eye height.
- Head pose as stock: the head is sampled at the display time; the client core predicts by the pipeline latency.

**Hands and controllers**

- Hands as controllers (on by default): your hands appear to the game as controllers, a pinch is that hand's
  trigger. The click is visionOS's own pinch gesture, the one the whole system uses, not a thumb-to-index
  distance from the hand skeleton (that missed real pinches and clicked when a hand was turned over). Two pinches
  in a row on the same hand (the second within 0.9 s of a short first one) also send that hand's A or X button,
  which the AirFrameXR desktop mirror reads as a double click, like a Quest's real button. Off sends the hand
  skeleton only.
- PlayStation VR2 Sense controllers: tested in game. The small Create (left) and Options (right) buttons reach the
  game as that hand's menu button, kept distinct because games bind them to different things. The PS button is
  not available to any app: visionOS 27 does not expose it in the controller's input profile, so the Home Button
  Overrides setting has nothing to act on and the PS button opens the Home View whatever you set. The app asks
  for it anyway, which will matter on controllers that do expose their Home button, and writes one `[home]`
  line per controller into the streamer log with what the profile contains.

**Window**

- One column: connection status, floor rows, four switches (Hands as controllers, Proximity chaperone,
  Performance HUD on the left forearm, Auto-connect) and Enter. No settings that duplicate the PC's.
- Auto-connect enters the stream as soon as the streamer connects.
- App name and icon: AirFrameXR.

**Building and shipping**

- GitHub Actions build on an Xcode 27 runner (`.github/workflows/`), including a TestFlight workflow that
  archives, signs with an App Store Connect API key and uploads, with an unsigned check mode that needs no
  account. No Mac is needed. Set-up guide for the account holder: `docs/TESTFLIGHT.md`. Every signed run creates a
  certificate on the Apple team and Apple caps their number; the workflow's "Revoke the certificates earlier runs
  created" input deletes the ones made through the API before signing.
- The ReplayKit eye-broadcast extension and the app group are removed, so a plain developer account suffices.
- Export compliance is declared in `Info.plist` (the stream is unencrypted by design).

## Building

Same as upstream: see the [Building](https://github.com/alvr-org/alvr-visionos/wiki/Building) wiki page. The CI
workflow files show the exact commands (Rust client core, cbindgen, `repack_alvr_client.sh`, then `xcodebuild`).

## 1.2.2 (2026-10-31)

- Finger pinches are ignored while a regular gamepad (DualSense, Xbox, Joy-Con) is connected. A pinch caught by accident used to take
  the trigger and pointer from the gamepad for a few seconds (user report). Tracked PS VR2 Sense controllers are not affected (they are
  handled per hand). Built by CI only; not tested on a headset. Any connected gamepad switches pinches off, used or idle.

## 1.2.1 (2026-10-30)

- The ring outside the declared frame follows the picture's own edge when a chroma key is on: opaque black where the edge is picture (a
  game), transparent where it is the key colour (between games, around the desktop mirror), so the idle passthrough is no longer framed
  in black. Drawn as four thin strips around the frame (no overdraw of the picture), one texture sample per pixel, only while a key is on;
  decided on the GPU from the decoded frame, so it changes on the same frame as the picture. Not measured on a headset yet (GPU time
  with and without the ring is the check owed).

## 1.2.0 (2026-10-29)

Released together with AirFrameXR streamer 1.2.0; the two are numbered together from now on. TestFlight builds 17
and 18 (version 1.2.0) carry everything below except the double tap, which is committed and not yet built.

- The declared field of view is a ceiling, the calibration lives on the PC (above). A second wearer who needed
  0.80 at the bottom could not get it before: the old fixed box stopped at 0.77.
- The hand click is the system pinch gesture (above). Found with a `[pinch]` debug line the calibration builds
  wrote every 2 s into the streamer's log: the hand was untracked 70 % of the time with the hand at the side, and
  the skeleton distance read 1.4 to 2.5 cm on real pinches against a 2 cm threshold.
- Black outside the frame whatever the chroma key, and the chroma key itself working again with it (the first
  attempt cleared to opaque black and discarded keyed pixels, which left that black in place; keyed pixels are
  now written transparent).
- Two pinches in a row send A / X: a double click on the desktop mirror. Not built or tried on a device yet.
- TestFlight workflow: the certificate revoke step; default version 1.2.0.

Not done, by choice: the pinch keeps Apple's recognizer timing (a deliberate pinch, no quick flick); nothing
calibration-related is set on the headset.

## Next

- The wearer's rectangle declared by the client itself, on the streamer's order (a host-to-client message on the
  v20 protocol's reserved packet): the stream frame could then cover only the rectangle, which the AirFrameXR
  measurements put at 30 % fewer encoded pixels on a full-frame stream. Until then the ceiling is what the stream
  covers.
- The field-of-view sweep drawn by the client itself, with the pinch read from hand tracking, if the streamed
  sweep (`tools/fov_calibration_bundle` in the AirFrameXR repository) proves too dependent on the hand staying in
  the cameras' view.
