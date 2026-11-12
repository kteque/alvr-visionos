# AirFrameXR client for Apple Vision Pro

The visionOS client of [AirFrameXR](https://github.com/jfbobier/AirFrameXR), wireless PC VR for NVIDIA cards: the
PC runs the game through AirFrameXR's OpenXR runtime (frame generation, foveated encoding, NVENC), streams it with
the ALVR v20 protocol, and this app shows it on the Vision Pro with hand and PlayStation VR2 Sense controller
tracking.

Version 1.3.10 (numbered with the AirFrameXR streamer it pairs with). Nearly feature complete; what is left is listed at the end.

How the app works inside (threads, the path of a frame, the client's own rules, what this fork changed and where):
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Credits

This app is a fork of [ALVR for Apple visionOS](https://github.com/alvr-org/alvr-visionos), written by
[Max Thomas (shinyquagsire23)](https://github.com/shinyquagsire23) and the alvr-org contributors, among them
panthurrr, zhuowei, shadowfacts, dereklucas, sidd, jfenton, svrc and robbiet480. The renderer, the tracking, the
ALVR client core integration, the controller and hand input, the chroma key and the TestFlight-ready project are
theirs. The streaming protocol and the client core are [ALVR](https://github.com/alvr-org/ALVR). Both are MIT
licensed and so is this fork (see `LICENSE`).

## What this fork adds

Everything below is in the release branch on top of upstream `main` (`airframexr-client` up to 1.3.9; 1.3.10 is on the branch
`1.3.10` until it is merged).

**Picture**

- Metal renderer only. The RealityKit renderer and its options are removed, so there is one code path to tune.
- Reconstruction filters, always on (1.3.8): the colour planes (4:2:0, half resolution) are rebuilt with a bicubic
  (Catmull-Rom) filter instead of the bilinear one the hardware formats use, and the luma gets the same filter where the
  encoded picture is stretched on screen (the periphery of a foveated stream, a small stream shown large). Where one
  encoded pixel covers one screen pixel the picture is unchanged. Colour edges are cleaner and the stretched areas sharper;
  nothing is sharpened or added, so any sharpening stays on the streamer. Details under 1.3.8.
- Field of view: the app declares the frustum the compositor asks for, as the stock app does at FoV Scale 1, so an
  uncalibrated wearer sees the whole panel. The wearer's own rectangle is set on the PC (the streamer's FOV card or
  the Vision Pro profile, 0.97 / 0.71 / 0.69 / 0.63) and only changes what the game renders. 1.2.0 to 1.3.1 cut the
  declared box to a fixed ceiling (1.03 / 0.79 / 0.75 / 0.86) instead: sharper, but black bars for wearers who see
  past it. Measurement and numbers: `docs/AVP_FOV.md` and `docs/FOV_CALIBRATION.md` in the AirFrameXR repository.
  The **Default FoV** switch (on = the stock app, both axes 1.0, turning it on resets them) hides or shows two **FoV sliders** (Horizontal and Vertical, 0.6 to 1.4, 1.0 in the middle) that scale the
  declared box per axis: less angle for the same stream (denser pixels, a cheaper game) at the price of the edges, more
  angle (above 1.0) the other way. With both equal the result is the same as the single FoV Scale of 1.3.5. They are read when
  you press Enter.
- The chroma key is taken from the streamer's settings (`video.passthrough`), so the key colour and distance are
  set once, on the PC. Keyed pixels are written transparent and everything the frame does not cover is black:
  you see the room between games (the streamer's idle colour) and around the desktop mirror's screen (its
  background is that colour), never past the frame's edge, and a game, which paints its own picture, is opaque.

**Staying up**

- Stream transitions do not take the app down: a game that loads for a long time, a streamer that rebuilds its encoder, a decoder
  that stops giving pictures, a short "background" report from visionOS (1.3.1).
- A lost link does not either: the app stays in the immersive space and the stream resumes by itself; after 60 s without a stream it
  goes back to its window, and auto-connect re-enters when the streamer is back (1.3.10).
- The render thread, the decoder and ALVR's client core share less: one lock for the shared stream state (1.3.1), no core call inside
  it, and the core sends its statistics outside its own lock (1.3.10).

**Space**

- Floor height: the height the headset reports is shown live in the window, with a manual offset (plus or minus
  50 cm) that is added to it. The sum is what the game sees as your eye height.
- Head pose as stock: the head is sampled at the display time; the client core predicts by the pipeline latency.

**Hands and controllers**

- No hand input: your hands never reach the game (no pinch click, no hand controller pose, no hand skeleton).
  Input comes from PlayStation VR2 Sense controllers, a Steam Controller or a gamepad (DualSense, Xbox, Joy-Con).
  Removed in 1.3.1 because the pinch kept sending commands nobody gave.
- PlayStation VR2 Sense controllers: tested in game. The small Create (left) and Options (right) buttons reach the
  game as that hand's menu button, kept distinct because games bind them to different things. The PS button is
  not available to any app: visionOS 27 does not expose it in the controller's input profile, so the Home Button
  Overrides setting has nothing to act on and the PS button opens the Home View whatever you set. The app asks
  for it anyway, which will matter on controllers that do expose their Home button, and writes one `[home]`
  line per controller into the streamer log with what the profile contains.

**Window**

- One column: connection status, the height line (HMD + offset = game height) with its offset slider, the Default FoV switch (and the two FoV sliders when it is off),
  two switches (Proximity chaperone, Auto-connect) and Enter. No settings that duplicate the PC's.
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
- Changes to ALVR's client core are carried as patches (`patches/*.patch`, applied by `scripts/apply_core_patches.sh` before the
  core is built), not as a fork of ALVR.
- A protocol harness (`tools/protocol-harness/`) runs the app's own `EventHandler.swift` on Linux against a scripted streamer:
  37 scenarios (transitions, stalls, link loss, pacing), ThreadSanitizer as an option.

## Building

Same as upstream: see the [Building](https://github.com/alvr-org/alvr-visionos/wiki/Building) wiki page. The CI
workflow files show the exact commands (`scripts/apply_core_patches.sh`, Rust client core, cbindgen, `repack_alvr_client.sh`, then
`xcodebuild`). `build_and_repack.sh` does the first four on a Mac.

## 1.3.10

Hardening against a lost or stalled link (AirFrameXR `docs/VISIONOS_CLIENT_HARDENING.md`). TestFlight build 71 (2026-11-12). Checked in
the protocol harness on Linux and, for the client_core patch, on the streamer's lab with the mock headset; **not yet tried on a
headset**. No change to pacing or picture.

- **A lost link no longer leaves a frozen scene.** The client stays in the immersive space and the stream resumes by itself when the
  streamer is back; after 60 s without a stream (`EventHandler.leaveStreamAfter`) it leaves the space for the Entry window, and
  auto-connect re-enters when the streamer is found again.
- **Shorter lock holds between the render thread, the decoder callback and client_core.** `alvr_report_frame_decoded` is called outside
  `frameQueueLock`, and client_core sends its statistics packet after releasing its statistics mutex
  (`patches/client_core-statistics-send-outside-lock.patch`, applied to the ALVR submodule by `scripts/apply_core_patches.sh` at build time).
- **Metal giving no command buffer skips the frame** instead of ending the app.

## 1.3.9

Pacing, measured on an M2 Vision Pro on 2026-11-10 (pacing test rig, then a TestFlight A/B on the headset). The picture work of 1.3.8 is unchanged.

- **The pick waits 8 ms for a late frame** (stock 5 ms): +1.1 points of new frames per tick, repeated ticks down by 29%, about 0.5 ms
  more queue age, a deadline-miss count that stays about 1 per 1000. `Renderer.swift`, the `pollFrameForDisplay` call.
- **100 Hz hack.** When the streamer asks for 90 Hz the client asks visionOS for 100 Hz (`VideoHandler.applyRefreshRate`), on every
  Vision Pro including the M5 so there is one rule. It is a request visionOS may refuse. The reason: the 100 Hz mode missed about 3 frames
  per 1000, a real 90 Hz stay about 23, and the headset ran 100 Hz in the sessions measured even when 90 was asked. The stream rate stays
  the negotiated one. If a later visionOS makes 90 Hz fine, delete the two lines of `displayRequest`.
- The telemetry added for 1.3.8 and the pose-fetch experiments (the `[tele]` lines in the streamer log) is removed; the catch-up pick stays as a lab switch (`EventHandler.catchUpPick`, off)
  because the protocol harness drives it.

## 1.3.8

Picture quality: two changes in the shader and the texture path, no setting for either.

- **Bicubic chroma.** The two colour planes of the 4:2:0 picture are half the luma resolution, so they are always enlarged.
  They are now sampled with a Catmull-Rom filter (`sampleCatmullRom5` in `Shaders.metal`: five bilinear taps with the weights
  renormalised, so the cost is five texture reads instead of the full sixteen). It passes exactly through the stored values, so
  flat colour and 1:1 areas do not change; colour fringes on edges (red on dark, text on a coloured background) are tighter.
- **Bicubic luma where the picture is stretched.** The same filter is used for brightness only where one stored texel covers
  more than about one screen pixel (decided per pixel from the sampling footprint): the foveated periphery, or a stream
  encoded below the screen's resolution. Elsewhere the plain bilinear sample is kept, so the centre costs nothing extra.
- **Own colour conversion.** To choose the filter, the video is read as two plain planes (`r8`/`rg8`, `r16`/`rg16` for 10-bit) and
  converted with the YCbCr matrix of the stream's encoding, instead of Apple's private converting formats, which filter the
  colour inside the sample where the shader cannot reach. The colour was checked on a Vision Pro by the owner (the first
  build with the filters: colours and sharpness good). `forceFastSecretTextureFormats` in `VideoHandler.swift` goes back to the old formats
  with one constant, filters and all.
- **Cost, measured on the device** (lines `[tele] draw over ...` in the streamer's `alvr.log`): the GPU draw takes about
  4.0 ms per frame at 100 Hz (2.2 ms with the hardware formats and no filters, on a different, larger stream, so the two
  numbers are not a clean comparison; the filter's share is at most the difference and is largest on a small stream). In
  196,388 frames, 4 command buffers finished after their presentation time; the GPU is not what misses a frame.
- Not in the client on purpose: sharpening (contrast adaptive or otherwise) alters the image and is done on the streamer.

Not picture: the frame pick shows the newer of two queued frames after a stall (less lag after a refresh-rate switch), the
client's refresh rate follows the rate the stream negotiates, and the `[tele]` lines in `alvr.log` (display interval, draw
cost, pick, CPU split) that these were measured with. See `docs/VISIONOS_TELEMETRY_LEARNINGS.md` in the AirFrameXR repository.

## 1.3.6

- Aligned with the AirFrameXR 1.3.6 PC package; this is the first build that carries everything below. `airframexr-client` is the
  release branch (the 1.4 line is retired: no streamer-driven view, the app keeps the FoV Scale slider).
- The encoding gamma the app asks the streamer for is now **1.2** (was 1.5), the value reported as the best for the Vision Pro; the app decodes with whatever the streamer negotiates, so a streamer that overrides it still wins. (Was committed after TestFlight build 1.3.5.)
- The **FoV Scale** slider (below, from 1.3.5) is in this build, as **two sliders**, Horizontal and Vertical (0.6 to 1.4, centred on 1.0) behind a **Default FoV** switch (on by default; turning it on resets both to 1.0). A setting saved by an earlier build
  is carried to both, with the switch off. Above 1.0 the app declares more angle than the compositor's frustum (1.3.5 capped at 1.0 after the old 1.1 did that): untested on a headset.
- The Performance HUD (left forearm) and the frame timing it needed are removed.
- The height rows are one line: `HMD 1.62 m + offset +5 cm = 1.67 m`. The Enter button has more room.

## 1.3.5

- The **FoV Scale** slider is back (0.70 to 1.00, 0.05 steps, 1.00 = the compositor's whole frustum), on top of the declared
  frustum: a user who likes a tighter, sharper stream can pick it without any calibration; the PC-side restriction is a
  separate control (it only changes what the game renders). The slider never goes above Apple's frustum (the 1.1 of the
  old build asked for more angle than the headset has).
- The temporary `[ratemap]` probe of 1.3.2 is removed: no diagnostic lines are written into the streamer's log any more.
- Version aligned with the AirFrameXR 1.3.5 PC package.

## 1.3.2 (not built yet)

- The fixed field-of-view ceiling is gone: the app declares the compositor's own frustum, as the stock app does at
  FoV Scale 1. A tester saw black bars with the streamer's restriction off on 1.3.1 and none on the stock app: the
  ceiling, measured on two wearers, was smaller than his view. Cost: the stream spreads over about twice the area
  (left eye 1.79 / 1.02 / 1.22 / 1.02 against about 1.05 / 0.80 / 0.76 / 0.87), so about 1.4 times fewer pixels per
  degree per axis, the stock app's sharpness. A calibrated wearer still gets the game restricted to the rectangle
  (the streamer converts the absolute tangents against the new box); the sharpness comes back only when the
  streamer can tell the app which box to declare (Next).
- (Removed in 1.3.5) TEMPORARY `[ratemap]` lines in the streamer's log, the compositor's rasterization rate map sampled
  across each eye.

## 1.3.1 (2026-11-02)

Stream transitions: the app going unstable, or closing itself, when the stream starts, when a game stalls or loads, or when the frame
rate drops. Found with a new protocol harness (`tools/protocol-harness/`, below) that runs the app's own `EventHandler.swift` on Linux
against a scripted streamer, plus ThreadSanitizer. TestFlight build 21 (the transition fixes, before the hand input below was
removed): testers report no transition errors any more (2026-11-02).

- All hand input is removed: the system pinch gesture (and the double pinch that sent A / X), hands as controllers, the hand skeleton, the
  "Hands as controllers" switch and the controllers-clack toggle. Users reported random commands from the pinch. ARKit hand tracking
  still runs, only to fuse the Steam Controller pose from the hands holding it. Without a controller, a Steam Controller or a gamepad the
  app now sends no input at all (so the desktop mirror cannot be clicked either). Settings saved by earlier builds are ignored.

- A game that sends nothing for 30 s (a long loading screen) no longer makes the app drop the connection. It reconnects only when
  frames arrive and none decode for 30 s.
- A new decoder when the streamer's stream configuration changes on the same connection (AirFrameXR does this when a game exits after
  a deferred stream change). The old decoder was kept and the picture froze until the app was restarted. A decoder that shows no
  picture for a second of frames is also rebuilt.
- The app no longer closes on a short "background" report from visionOS: it leaves once the background state has held for one second.
- The decoder, the frame queue and the last shown frame are shared by the network, render and event threads. They are now read and
  written under one lock, so a stream stop or restart cannot swap them under a thread that is using them. These were ThreadSanitizer
  findings and crash candidates at every transition.
- Smaller fixes:
  - A tracking worker that could wait forever after startup.
  - Render pipeline rebuilds run one at a time (several used to run at once at every stream start).
  - A frame finished after its presentation time reports no queue time, instead of a wrapped value that held head prediction at its
    cap.
- Transitions write `[stream]` lines into the streamer's log: decoder rebuilds, the reconnect rule, background exits. If the app
  still closes, look there first.

Not covered by the harness: Metal, the real VideoToolbox and the visionOS watchdog. Its streamer answers an IDR request instantly,
so its recovery times are best cases.

**Protocol harness:** `tools/protocol-harness/build.sh [--tsan]` then `run.sh [--tsan]` (Swift for Linux, no Mac). In the AirFrameXR
repository, `python3 harness/stability/run_stability.py client [--tsan]` runs the same thing. Before / after on the same 15
scenarios:

| Scenario | 1.2.2 | 1.3.1 |
|---|---|---|
| 35 s stall | the app drops the connection | passes |
| encoder rebuilt mid-connection | picture frozen | passes |
| 0.3 s background report | the app closes | passes |
| idle to game, fps drops, 1 / 6 s stalls, choking game, irregular cadence, restarts | pass | pass |
| ThreadSanitizer | races on the decoder and the last shown frame | only simple counters and timers left |

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

- 1.3.10 on a headset: a link loss shorter and longer than 60 s, and a normal session.
- The wearer's rectangle declared by the client itself, on the streamer's order (a host-to-client message on the
  v20 protocol's reserved packet): the stream frame could then cover only the rectangle, which the AirFrameXR
  measurements put at 30 % fewer encoded pixels on a full-frame stream. Until then the stream covers the
  compositor's whole frustum (or what the FoV sliders make of it).
