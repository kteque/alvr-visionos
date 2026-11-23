# AirFrameXR for Apple Vision Pro

The visionOS client of [AirFrameXR](https://github.com/jfbobier/AirFrameXR): wireless PC VR for NVIDIA graphics cards. The PC runs
the game through AirFrameXR's OpenXR runtime (frame generation, foveated encoding, NVENC) and streams it with the ALVR v20
protocol. This app shows the stream on the Vision Pro and sends back head tracking and controller input.

**Try it:** [join the public TestFlight beta](https://testflight.apple.com/join/QYxnfNWM) (limited to 100 testers). It needs the AirFrameXR streamer on a Windows PC with an NVIDIA GPU on the same network.

Version 1.4.1 (numbered with the AirFrameXR streamer it pairs with). The version history is in [docs/CHANGELOG.md](docs/CHANGELOG.md).

---

# Part 1: User manual

## What you need

- An Apple Vision Pro. The PSVR2 Sense controllers need visionOS 26 or later; visionOS 27 is what the app is built against.
- A Windows PC with an NVIDIA graphics card running the AirFrameXR streamer, on the same network. The app finds the PC by itself.
- A controller: PlayStation VR2 Sense controllers (best supported), a Steam Controller, or a gamepad (DualSense, Xbox, Joy-Con).
  Your hands do not reach the game: there is no pinch input (one opt-in exception for gamepads, see Switches).

## The window

When you open the app you see one window, from top to bottom:

1. **The logo and the version**, and the **connection status** with a coloured dot: orange while it looks for your PC, green when it is
   connected to it.
2. **The Auto-connect card** (see below).
3. **The height line**, for example `HMD 1.62 m + offset +5 cm = 1.67 m`: the height the headset reports, your offset, and what the game
   gets as your eye height. The slider moves the offset by up to 50 cm either way. Use it if the game puts you too low or too high.
4. **The switches**: Proximity chaperone, Hands tracking for gamepad, Stream audio when headset removed, Auto-recenter on stream start, Flat2VR mode for PSVR2 buttons.
5. **The recenter reminder**: Recenter = Create + Options.
6. **Enter**, which starts the stream once the PC is connected. It reads "Connecting..." until then.

The field of view, the sharpness and the picture settings are not here: they are set once, on the PC, in the AirFrameXR streamer.

## Auto-connect

With Auto-connect on, the app enters the stream by itself the moment your PC is found: put the headset on, start the streamer, and you
are in. It has its own card at the top, tinted green when on, because it changes how the app behaves.

**To change a setting while Auto-connect is on, leave the stream first** (press the Digital Crown), change the setting in the window, then
press Enter again. You are not pulled back in while the connection is still up: auto-connect only fires when the connection is made, so
leaving on purpose keeps you in the window until the next connection. When the stream is lost for more than a minute, the app leaves the
stream and Auto-connect enters again when the PC is found.

Off by default.

## Switches

**Proximity chaperone** (off by default). When your hands or controllers come within 30 cm of a wall or a piece of furniture the headset has
mapped, the surface is drawn in the game and the controller pulses. It is a safety net, not a boundary: it only knows what the headset has
seen.

**Hands tracking for gamepad** (off by default). A gamepad without tracking, such as a Joy-Con, has no position of its own. With this on, the hand
holding it gives the game one: a single Joy-Con moves its own hand, a pair or any other gamepad moves both. Pose only, never a pinch or a click, and
PlayStation VR2 Sense or Steam controllers take priority. Not tested on a headset yet.

**Stream audio when headset removed** (on by default). Take the headset off to open the door and the game keeps running and its audio keeps
playing, with no picture. Put the headset back on and the picture returns by itself. The app stays alive in the background for up to 30
minutes this way; after that, or with the switch off, taking the headset off ends the session as it did before. Not tried for the full 30
minutes on a headset: how long visionOS lets the app run in the background is the unknown.

**Auto-recenter on stream start** (off by default). A moment after each stream starts, your head's position on the floor and the way you are
facing become the centre of the game. Useful when you start the game from a different spot or direction every time.

**Flat2VR mode for PSVR2 buttons** (on by default). Flat2VR games are built for an Xbox controller: Create is View and Options is Menu. This
switch is the place for that mapping. **It has no effect yet**: the stream is seen by the game as a Quest 2 controller, which has no View
button, so the mapping needs a streamer-side change first. The setting is saved so it will keep its value when the mapping arrives.

## Recentering

- **Create + Options together** (the small buttons on the two PSVR2 Sense controllers): press both at once and the game's centre moves to
  where your head is, facing the way you look. Only your position on the floor and your heading change; the floor stays the floor. While
  both are down, the buttons are not sent to the game, so Create does not pause games that use it as Pause. If your left press lands a
  few milliseconds before the right one, a game can still see a short pause.
- **Long press on the Digital Crown**: the visionOS recenter. It works as it always does.
- **Auto-recenter on stream start**: the switch above.

## The PSVR2 Sense controllers

The small Create (left) and Options (right) buttons reach the game as that hand's menu button, and are kept distinct because games bind
them to different things. In most games only the left one does anything (usually Pause), and the right one does nothing. The PS button
is not available to any app: visionOS does not pass it on, so it opens the Home View whatever you set, and the app cannot change that.

## If something goes wrong

- **Black picture or bars**: the field of view is the streamer's. Check the FOV settings on the PC.
- **The stream freezes**: the app stays in the stream and resumes by itself when the PC is back. After 60 seconds without a stream it
  returns to the window.
- **The app was not found / does not connect**: both devices must be on the same network. The streamer's log (`AirFrameXR.log` on the
  PC) holds `[stream]`, `[view]` and `[home]` lines from the headset that say what happened.

---

# Part 2: Technical architecture

## Overview

```
Game (OpenXR / OpenVR via OpenComposite)
   -> AirFrameXR runtime (VDXR + ovrshim) -> host (frame generation, foveation, NVENC)
   -> ALVR v20 protocol over the network (video, audio, tracking, buttons, one small control channel)
   -> this app: decode (VideoToolbox) -> Metal renderer -> visionOS compositor
```

This repository is the last box. The PC side lives in the AirFrameXR repository (`docs/ARCHITECTURE.md` there).

## The app

- **Entry window** (`ALVRClient/Entry/`): SwiftUI. Connection state, the settings above, the Enter control. Settings are in
  `GlobalSettings.swift` and saved to the device as JSON; unknown or old keys are ignored.
- **Event handler** (`EventHandler.swift`): owns the connection. It reads events from the ALVR client core (Rust, linked as a
  static library), starts and stops the decoder, holds the stream through short background states, and applies the 60 s link-loss rule.
- **Decoder** (`VideoHandler.swift`, `NALParser.swift`): H.264, HEVC or AV1 NAL units into VideoToolbox. A decoder is rebuilt when the stream
  configuration changes, when a frame is refused after a background, or when a second of frames shows no picture.
- **Renderer** (`Renderer.swift`, `MetalClientSystem.swift`, `Shaders.metal`): a Metal layer in a fully immersive space. The video is read
  as plain luma and chroma planes and converted in the shader with the stream's own YCbCr matrix.
- **Tracking and input** (`WorldTracker.swift`, `Input/`): head pose sampled at display time and predicted by the client core's pipeline
  latency; controller poses and buttons mapped onto the Quest 2 (Touch) paths the streamer expects; Steam Controller over Bluetooth
  (`Input/SteamControllerDevice.swift`); proximity chaperone from ARKit planes (`ChaperoneSystem.swift`).
- **Frame pick**: each display tick takes the newest decoded frame, waiting up to 8 ms for a late one (stock 5 ms).
- **Refresh rate**: when the streamer asks for 90 Hz the app asks visionOS for 100 Hz (the 100 Hz mode missed fewer deadlines in
  measurement). It is a request visionOS may refuse.

## Picture pipeline

- **Chroma**: the half-resolution colour planes are reconstructed with a Catmull-Rom filter (five bilinear taps with renormalised weights)
  instead of the bilinear one the hardware formats use. Colour edges are tighter.
- **Luma**: the same filter where one stored texel covers more than about one screen pixel (the foveated periphery, a stream encoded below
  the screen's resolution); the plain sample elsewhere.
- **Sharpening (1.4)**: an optional single-pass AMD FidelityFX **Contrast Adaptive Sharpening (CAS)** in its "sharpen and scale" form,
  on the luma plane only. It is made for the 1.2 to 1.7 x magnification at the centre of the view (the Vision Pro samples up to 40
  pixels per degree). It is **off unless the streamer switches it on**; sharpness is a streamer setting, never an app setting.
- **Chroma key**: taken from the streamer's settings. Keyed pixels are written transparent; everything the frame does not cover is
  black, or transparent when the picture's own edge is the key colour, so the room shows between games and around the desktop mirror.

## The streamer owns the field of view (1.4)

The app does not have field-of-view settings. For each connection the streamer decides which box of the headset's view the game renders
and sends it over the ALVR v20 `Reserved` control packet, a small JSON message resent about once a second:

```
{"airframexr":1,"view":{"left":[outer,inner,upper,lower],"right":[...]},"sharpen":true}
```

The app declares that box to the compositor as it is, clamped to the compositor's circumscribed frustum, and re-declares it whenever it
changes. With no message (an older streamer) the app declares the compositor's whole frustum, as the stock app does. The message and the
box are per connection and reset on every disconnect. The message is carried by a patch to the ALVR client core
(`patches/client_core-reserved-message.patch`). Design and measurements: `docs/FOV_CONTRACT_PLAN.md` in the AirFrameXR repository.

## Recentering

`WorldTracker.recenterOnHead()` makes the head's floor position and heading the stream's origin by setting the transform that every pose
already goes through (head, controllers, hands), so nothing else changes. It runs on the Create + Options chord
(`updateRecenterChord`, edge triggered, both menu buttons down) and, if the setting is on, about 90 poses after a stream starts.
The streamer is told through the playspace message. visionOS's own recenter (long Crown press) changes the origin underneath; the
old triple-press detection only runs with `keepSteamVRCenter`, which nothing in the app sets.

## Staying alive

- **Headset off**: the app holds the connection up to 30 minutes (`backgroundHoldMax`), drops decoded video, keeps sending fake tracking so
  the streamer does not see the headset vanish, and leaves the audio session on (`UIBackgroundModes: audio`). On return the decoder is
  rebuilt from the saved parameter sets with a keyframe, and the immersive space is opened again if it has not rendered after 2 s.
- **Lost link**: the scene stays and the stream resumes by itself. After 60 s without a stream the app leaves for the window;
  Auto-connect enters again when the PC is found.
- **Locks**: the decoder, the frame queue and the last shown frame are guarded by one lock; client core statistics are sent outside its
  mutex (`patches/client_core-statistics-send-outside-lock.patch`). Found with ThreadSanitizer in the protocol harness.

## Testing

- **Protocol harness** (`tools/protocol-harness/`): runs the app's own `EventHandler.swift` on Linux (Swift for Linux, no Mac) against a
  scripted streamer: stalls, decoder rebuilds, background reports, restarts, ThreadSanitizer. It does not cover Metal, the real
  VideoToolbox or the visionOS watchdog.
- **Steam Controller harness** (`tools/steam-controller-harness/`).
- Everything else is tested on a headset; `docs/CHANGELOG.md` says what was and was not.

## Building and shipping

- GitHub Actions on an Xcode 27 runner (`.github/workflows/`): an unsigned check that needs no account, and a TestFlight workflow that
  archives, signs with an App Store Connect API key and uploads. The build number is the run number. No Mac is needed. Set-up guide:
  `docs/TESTFLIGHT.md`; App Store submission: `docs/APPSTORE.md`.
- The client core (Rust) is built with cargo and cbindgen, then the xcframework and `xcodebuild`; the CI files show the exact commands.
  Patches to the ALVR submodule are applied by `scripts/apply_core_patches.sh`.
- Export compliance is declared in `Info.plist` (the stream is unencrypted by design).

---

# Part 3: Credits

- **[ALVR for Apple visionOS](https://github.com/alvr-org/alvr-visionos)**, which this app is a fork of, written by
  **[Max Thomas (shinyquagsire23)](https://github.com/shinyquagsire23)** and the alvr-org contributors, among them panthurrr, zhuowei,
  shadowfacts, dereklucas, sidd, jfenton, svrc and robbiet480. The renderer, the tracking, the client core integration, the controller
  and hand input, the chroma key and the TestFlight-ready project are theirs.
- **[ALVR](https://github.com/alvr-org/ALVR)**: the streaming protocol and the client core.
- **AMD**: the contrast adaptive sharpening is AMD's **FidelityFX Contrast Adaptive Sharpening (CAS)**, published through GPUOpen under the
  MIT licence, adapted to Metal. Copyright Advanced Micro Devices, Inc.
- **AirFrameXR** (PC side, frame generation, foveation, the FoV contract) and the changes in this fork: Jean-Francois Bobier.

# License

MIT. Copyright (c) 2026 Jean-Francois Bobier, for the changes and additions in this fork; copyright (c) 2024 alvr-org for the code it is
based on. Both notices are kept in `LICENSE`, as the MIT licence requires. The AMD FidelityFX CAS code keeps its own MIT notice (AMD).
