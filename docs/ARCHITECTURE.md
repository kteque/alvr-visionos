# How the AirFrameXR visionOS client works

Written 2026-11-12 from the code of client 1.3.10. It describes what the app does at run time: the threads, the path of a video
frame, the path of a head pose, the boundary with ALVR's client core, and the rules the client applies on its own. What this fork
changed is marked **[fork]**, with the version that brought it; the per-version history is in `README.md`.

How to read the claims: everything here was read in the code. Parts that were only skimmed say so. Nothing in this file is a
measurement; numbers and their sources are in `README.md` and in the AirFrameXR repository (`docs/VISIONOS_CLIENT_HARDENING.md`,
`docs/VISIONOS_TELEMETRY_LEARNINGS.md`).

## 1. The shape of it

```
 PC (AirFrameXR streamer, ALVR v20 protocol)
        |  UDP stream socket: video, tracking, statistics      TCP control socket: events, config, IDR requests
        v
 client_core (Rust, ALVR submodule + patches/)   <- one static library, called through the C API alvr_*
        |  decoder callback (video thread)        |  alvr_poll_event (event thread)
        v                                         v
 EventHandler.handleNals                    EventHandler.handleAlvrEvents
        |  VideoToolbox, synchronous              |  stream start / stop, decoder config, haptics
        v                                         v
 frame queue (max 2 frames, frameQueueLock)   state: streamingActive, decoder session, link-loss timer
        |
        v
 Renderer.renderFrame (render thread, one CompositorServices frame per display tick)
        |  pick a frame, ask the core for the pose it was rendered for, draw it where that pose says,
        |  send the next head pose and the controllers
        v
 visionOS compositor (LayerRenderer drawable, device anchor attached)
```

The app is a thin shell around three things it does not own: ALVR's client core (network, protocol, statistics), VideoToolbox
(decode) and CompositorServices + ARKit (display, head and controller poses). Its own code is the glue, the frame pick, the shader
that turns the decoded picture into the drawable, the input mapping and the window.

## 2. Source map

| File | What it holds |
|---|---|
| `ALVRClientApp.swift` | The SwiftUI app: the Entry window, the `MetalClient` immersive space, the `InputDebug` window and space, the layer configuration (`ContentStageConfiguration`: layered layout, foveation on, `rgba16Float`, depth 32). The Entry window's `.task` starts everything. |
| `Entry/Entry.swift`, `Entry/EntryControls.swift` | The window: connection status, height line and offset, FoV switch and sliders, chaperone and auto-connect switches, the Enter toggle. Enter opens the immersive space. |
| `EventHandler.swift` | The protocol layer: `OutgoingWorker` (lossy send threads), core initialisation, the event thread, the NAL callback and decoder lifecycle, the frame queue and the frame pick, the client's own rules (section 8). The only client file the Linux harness compiles. |
| `MetalClientSystem.swift` | The render thread and its loop over the `LayerRenderer` state (running / paused / invalidated). |
| `Renderer.swift` | `renderFrame` (one frame, section 5), the Metal pipelines and their rebuild, the passes: video frame, border ring, overlay (room wireframe), chaperone, depth. |
| `Shaders.metal`, `ShaderTypes.h` | The video-frame shader: foveation decompression, bi-planar YCbCr sampling with the Catmull-Rom filter, colour conversion, encoding gamma, chroma key; plane / HUD / copy shaders. |
| `VideoHandler.swift` | Decoder creation (H.264, HEVC, AV1), Annex B to sample buffer, `feedVideoIntoDecoder`, pixel-format tables, the YCbCr matrix of the stream, the display refresh-rate request. |
| `NALParser.swift`, `AV1Parser.swift` | Parameter-set extraction and the AV1 sequence header (upstream). |
| `WorldTracker.swift` | ARKit: session and providers, world origin anchor, floor height, planes; `sendTracking` (head, controllers, hands for the Steam Controller fusion), gamepad and PS VR2 Sense input, haptics, the view parameters. The largest file; read in parts only. |
| `Input/` | The device-neutral input stack: `InputSnapshot`, `InteractionProfile` tables and `InputRouter`, `InputSink` (the only place `alvr_send_button` should live for new devices), the Steam Controller over CoreBluetooth (`SteamControllerDevice`), its 6DoF pose fused from the hands and the IMU (`ControllerPoseFuser`), its geometry (`IbexModel`), and the offline debug view. |
| `ChaperoneSystem.swift` | Proximity chaperone from ARKit planes, with haptics. |
| `FFR.swift` | Foveation variables from the stream's start event and the streamer's settings, as Metal function constants. |
| `ChromaKey.swift` | The chroma key parameters, from the streamer's `video.passthrough` or the client's own settings. |
| `FovScale.swift` | The two FoV sliders' maths (`declaredFovAngles`); imports only `simd` so the harness can check it. |
| `GlobalSettings.swift` | The client's own settings, saved as JSON in Documents. |
| `Settings.swift` | The streamer's settings JSON as the core hands it over (`alvr_get_settings_json`), decoded for the few fields the client reads. |
| `CameraView.swift` | Face tracking from the persona camera (upstream; not read for this document). |
| `Extensions/` | Frustum tangents from a drawable's projection, the canted-view correction, `GCController` helpers (spatial controllers, the Home button claim), small SwiftUI and simd helpers. |

## 3. Threads

| Thread | Started by | Does | Blocks on |
|---|---|---|---|
| Main | SwiftUI | The window, opening and dismissing the immersive space, `exitIfBackgrounded` (dispatched every 100 ms by the event thread), the display-rate request | nothing of ours |
| Event thread ("Events Thread") | `EventHandler.start` | `handleAlvrEvents`: polls `alvr_poll_event`, about every millisecond when idle; stream start and stop, decoder config, haptics; the timers of section 8; battery and mDNS announcements | `frameQueueLock` briefly |
| Event watchdog | `EventHandler.start` | Every 6 s: a second path to `exitIfBackgrounded`. Its restart-and-exit branch cannot fire (`numberOfEventThreadRestarts` is never incremented) | - |
| client_core's threads | the core | Connection, receive, audio. The **video thread** calls our decoder callback `handleNals` for every frame | whatever `handleNals` does (the decode is synchronous) |
| Decoder output | VideoToolbox | The completion block of `VTDecompressionSessionDecodeFrame`. With flags 0 the decode is synchronous, so in practice this runs on the core's video thread, inside `handleNals` | `frameQueueLock`, the core's statistics mutex |
| Render thread ("Render Thread") | `MetalClientSystem.startRenderLoop` | `renderLoop` and `Renderer.renderFrame`, once per display tick | the compositor's clock, `frameQueueLock`, the core's statistics mutex (one call per new frame) |
| Metal completion handler | Metal | After the GPU work of a frame: `markSubmitted` and `alvr_report_submit` | `frameQueueLock`, the core's statistics mutex and its send |
| `OutgoingWorker` x2 (3 threads each: "Outgoing Data", "Tracking Worker") | `EventHandler` | Run closures that call `alvr_send_tracking_and_face_data` and friends. One slot per thread, a new closure replaces an unstarted one: **lossy by design**, a stuck send costs a tracking sample, not the render thread | the core's sockets |
| Pipeline rebuild queue | `Renderer.requestPipelineRebuild` | Compiles the Metal pipelines off the render thread, one at a time **[fork 1.3.1]** | Metal |
| ARKit tasks | `WorldTracker.initializeAr` | `async` loops over world, plane, scene-reconstruction and accessory updates | ARKit |
| CoreBluetooth | `SteamControllerManager` | The Steam Controller's reports and its keep-alive | - |

## 4. Life cycle

1. **Launch.** The Entry window appears. Its `.task` runs `EventHandler.initializeAlvr()` (once: `alvr_initialize` with the
   capabilities, `alvr_set_decoder_input_callback`, `alvr_resume`), `WorldTracker.initializeAr()` (only when the ARKit session is not
   already running **[fork 1.3.10]**), then `EventHandler.start()` (event thread and watchdog).
2. **Discovery and connection** are the core's: it announces the headset and waits for the streamer. The client adds an mDNS
   listener. The window shows the core's HUD message (`parseMessage`).
3. **Stream start.** `STREAMING_STARTED`: the client stores the negotiated refresh rate, encoding gamma and HDR flag, sets
   `streamingActive` and shows "connected". `DECODER_CONFIG` follows: the decoder session is built from the parameter sets
   (`installDecoder`). Until the wearer enters, the event thread sends a fake tracking sample every 100 ms so the streamer keeps a
   stream alive, and `handleNals` accepts frames without decoding them.
4. **Enter.** The Enter toggle (or auto-connect, on the edge to "connected") opens the `MetalClient` immersive space.
   `CompositorLayer` hands a `LayerRenderer` to `MetalClientSystem`, which builds the `Renderer` (this sets `renderStarted`) and
   starts the render thread. The first streamed frames declare the views (section 6); frames are shown once the views were sent and
   a refresh-rate's worth of frames has been drawn.
5. **Streaming.** Sections 5 and 6.
6. **Stream stop** (`STREAMING_STOPPED`: the streamer ended it, or the core's keep-alive found the link dead): `stop()` clears the
   decoder, the queue and the last shown frame under the lock. The render loop keeps running and draws the room wireframe overlay.
   The core keeps listening, so the next `STREAMING_STARTED` resumes in place. **[fork 1.3.10]** After 60 s without a stream
   (`leaveStreamAfter`) the event thread sets `leaveRequested` and asks the UI (`onLeaveStream`) to dismiss the immersive space and
   bring the Entry window back; the render loop sees the invalidated layer, ends without `alvr_pause` or `exit`, and auto-connect
   re-enters at the next connection.
7. **Leaving on purpose.** The wearer closes the space: the layer goes `invalidated`, the loop calls `alvr_pause()` and ends; if that
   happens within a second of the loop's start the app exits. The app also exits once visionOS has reported it in the background for
   one second (section 9).

## 5. A video frame, from the socket to the eye

1. **Receive.** The core reassembles a frame and calls `handleNals` on its video thread. Returning `false` tells the core the frame
   was not taken; the core then asks the streamer for an IDR. That is how the client requests a key frame (`resetEncoding()` sets a
   flag that makes the next `handleNals` return `false`).
2. **Gate.** Not in the immersive space: the frame is acknowledged and dropped. A frame more than 600 ms behind the last pose
   requested (after two seconds' worth of frames since the last IDR), or two seconds of display ticks with no decode: drop and ask
   for an IDR ("lag spike", upstream).
3. **Decoder session.** Taken with its format under `frameQueueLock`. A pending rebuild (no picture for a second of frames) is done
   here, between two decodes **[fork 1.3.1]**.
4. **Decode.** `VideoHandler.feedVideoIntoDecoder`: Annex B to a sample buffer, `VTDecompressionSessionDecodeFrame` with flags 0
   (synchronous). A decode error after two seconds' worth of frames since the last IDR asks for another.
5. **Output block.** No picture: `noteDecodeFailure`. (An upstream "decode overrun" branch follows; its limit as written is 50,000 s,
   so it never fires.) Otherwise
   `alvr_report_frame_decoded(timestamp)` is called **outside** `frameQueueLock` **[fork 1.3.10]**, then under the lock the frame is
   appended to `frameQueue`; the queue is capped at 2, the oldest goes.
6. **Pick.** The render thread calls `pollFrameForDisplay(timeout: 0.008)` **[fork: locked 1.3.1, 8 ms 1.3.9]**:
   - the last frame was not confirmed submitted and fewer than 2 are queued: **resubmit** it;
   - a frame is queued: **fresh** (with the lab switch `catchUpPick` the newer of two; off in releases);
   - nothing within 8 ms: the last frame again, **reprojected**; no last frame: nothing, the overlay is drawn.
7. **Pose of the frame.** For a fresh frame the render thread calls `alvr_report_compositor_start(timestamp)`: the core returns
   the head pose it sent with that timestamp, composed with the views. That is the pose the game rendered the frame for.
8. **Draw.** The picture is drawn on a quad placed with that pose, seen from the device anchor queried for this presentation
   time, so head rotation since the frame was rendered is corrected by geometry; the device anchor is also attached to the drawable
   for the compositor's own correction. (The pass code was read in outline only.) The fragment shader undoes the foveated encoding, samples the two planes (Catmull-Rom for
   chroma, and for luma where the picture is stretched) **[fork 1.3.8]**, converts YCbCr with the stream's matrix, applies the
   encoding gamma and the chroma key.
9. **Submit.** The command buffer is committed; its completion handler calls `markSubmitted` (true the first time a timestamp is
   submitted) and then `alvr_report_submit`, which closes the frame's statistics and sends them to the streamer.

The frame's statistics are what the streamer's latency figures and its head-prediction offset are made of: decoded, compositor
start and submit must be reported once per frame, in that order.

## 6. One render tick (`Renderer.renderFrame`)

In order: `queryNextFrame`, `predictTiming`, `startUpdate` / `endUpdate` (empty), wait until the optimal input time,
`startSubmission`, the pick (5.6), the command buffer, `queryDrawable(s)`, the pose of the frame (5.7), the view configuration, the
tracking for the next frame, the device anchor, the passes, `encodePresent`, `commit`, `endSubmission`, then `publishShownFrame`.

- **Early returns.** No frame from the layer, no timing: return before anything is started. No command buffer **[fork 1.3.10]** or
  no drawable: return after `startSubmission`, without `endSubmission`, republishing the picked frame. Apple's own sample loop
  returns the same way when there is no drawable.
- **View configuration.** On the first streamed frame, when the distance between the eyes changes by more than 1 mm, or when the
  FoV sliders changed: the frustum tangents of the drawable's views are scaled per axis (`declaredFovAngles`) **[fork]**, corrected
  for the canted displays into the orthogonal views the PC side expects, and sent with `alvr_send_view_params`. Frames are not
  shown until this has happened and frames rendered for it have arrived.
- **Pipelines.** Rebuilt (off the render thread) when the views are first declared, when the encoding gamma, the stream's YCbCr
  matrix or the chroma key change. Foveation, gamma and key are compile-time constants of the shader, which is why a rebuild is
  needed.
- **What is drawn.** Streaming and suitable: the video frame, the border ring when a chroma key is on **[fork 1.2.1]**, then the
  frame overlays (chaperone). Otherwise: the room wireframe overlay, faded in. A second of reprojected frames in a row fades the
  wireframe in over the picture.

## 7. Head, controllers, input

- **Head.** Every tick, after the view configuration, `WorldTracker.sendTracking` queries the device anchor for the presentation
  time of the frame being drawn (walking back 5 ms at a time when ARKit refuses a future timestamp), converts it to the streamer's
  space (world origin anchor, floor correction, height offset **[fork]**) and queues `alvr_send_tracking_and_face_data` on the
  outgoing worker. The timestamp sent is the one the frame for that pose will come back with: it is the key the whole pipeline is
  matched on. The core predicts the head further by the measured pipeline latency.
- **Controllers.** PS VR2 Sense: ARKit `AccessoryTrackingProvider` anchors, predicted to the target time; buttons through
  GameController. Gamepads: buttons only. Steam Controller: reports over CoreBluetooth, pose fused from the hands that hold it and
  its IMU; ARKit hand tracking runs only for that. **[fork 1.3.1]** Hands themselves never reach the game.
- **Buttons** go through `alvr_send_button`; new devices should go through `Input/InputSink` and an `InteractionProfile` table
  rather than add calls in `WorldTracker`.
- **Haptics** arrive as events on the event thread, which stores them for `WorldTracker`; it drives the controllers' haptic engines.
- **Space.** A world anchor marks the origin (`worldOriginAnchor`); the floor height comes from ARKit's floor planes
  (`largestFloorHeight`); the Entry window shows the head height live.

## 8. The client's own rules

These are decisions the client takes without the streamer. Each one is a transition that can go wrong, and each has a scenario in
the protocol harness.

| Rule | Where | Since |
|---|---|---|
| No NAL for 5 s while initialised: ask for an IDR | event thread | upstream |
| Frames arrive (a NAL within the last second) but none decoded for 30 s: `alvr_report_fatal_decoder_error`, the core reconnects. Silence from the streamer alone is not a fault | event thread | **[fork 1.3.1]** (upstream reconnected on silence) |
| Decoder config with other parameter sets on the same connection: new decoder session | event thread | **[fork 1.3.1]** |
| No picture for a second of frames: rebuild the decoder session from the stored config | `noteDecodeFailure`, `handleNals` | **[fork 1.3.1]** |
| Lag spike, decode overrun, decode error: IDR | `handleNals`, `VideoHandler` | upstream |
| Background reported for 1 s: exit | main thread | **[fork 1.3.1]** (upstream: at once) |
| No stream for 60 s inside the immersive space: back to the Entry window | event thread, UI | **[fork 1.3.10]** |
| The stream asks for 90 Hz: the display is asked for 100 Hz; the stream keeps its rate | `VideoHandler.applyRefreshRate` | **[fork 1.3.9]** |

Rare transitions write a `[stream]` line through `EventHandler.streamLog` **[fork 1.3.1]**: it goes to the core's logger at error
level, so it lands in the streamer's log on the PC (`AirFrameXR.log`). Never per frame.

## 9. Ways the app ends on its own

- `exit(0)`: background for one second (`exitIfBackgrounded`); the layer invalidated within a second of the render loop's start
  (`MetalClientSystem`); the event watchdog (unreachable).
- `fatalError`: ARKit session start, pipeline compilation, render encoder creation, texture cache, settings load and save.
- `try!`: three `CMBlockBuffer` creations.

None is on a path that depends on the network. A death that is not one of these is the system's (a watchdog or a crash); the
headset's crash report (`.ips`) is the place to look, the client leaves no record of its own.

## 10. Shared state and locks

| Lock | Protects | Taken by |
|---|---|---|
| `frameQueueLock` (`objc_sync`) | decoder session + format + config bytes, `frameQueue`, last shown frame, last submitted timestamp, decode-error counters | event thread, video thread / decoder output, render thread, Metal completion handler **[fork 1.3.1]** |
| the core's `statistics_manager` mutex (inside client_core) | per-frame statistics | `alvr_report_frame_decoded` (decoder output), `alvr_report_compositor_start` (render thread), `alvr_report_submit` (completion handler), `alvr_send_tracking*` (outgoing worker) |
| `arkitLock`, `controllerLock`, plane and debug locks (`WorldTracker`) | ARKit session setup, controller anchors, plane cache | ARKit tasks, render thread |
| `pipelineRebuildLock` | one queued rebuild at a time | render thread, rebuild queue |

Rules that follow:

- Shared stream state is read and written under `frameQueueLock` only; the render thread goes through `pollFrameForDisplay`,
  `publishShownFrame` and `markSubmitted`.
- **No core call under `frameQueueLock`** **[fork 1.3.10]**: the core has its own mutex, and holding ours across it lets a slow
  core call stop the render thread's pick.
- The core's statistics packet is sent **after** its mutex is released **[fork 1.3.10]**
  (`patches/client_core-statistics-send-outside-lock.patch`): a send that waits on the socket must not hold up the three other
  callers.
- Known and left: plain timers and counters (`timeLastFrameSent`, `framesSinceLastDecode`, `currentCodec`, `streamingActive`,
  `renderStarted`...) are read and written by several threads without a lock; ThreadSanitizer reports them. `initializeAr` holds
  an `objc_sync` lock across an `await`; `controllerToAlvrDeviceMotion` holds `controllerLock` across an ARKit call; the render
  thread reads pipeline state that the rebuild queue writes.

## 11. Settings

- **Client** (`GlobalSettings`, a JSON file in Documents): height offset, auto-connect, FoV sliders, chaperone distance, chroma
  key source, hands overlay, dismiss the window on Enter, the stream rate preference. Saved when Enter is pressed.
- **Streamer** (`Settings`, read from the core): the passthrough / chroma key, foveation, controller emulation. Cached; the cache
  is cleared on stream start, stop, decoder config and HUD messages.
- Policy **[fork]**: nothing that duplicates a PC-side setting, nothing about field-of-view calibration on the headset.

## 12. Building

- `ALVR/` is a submodule of upstream ALVR (the client core, pinned). Our changes to it are **patches**, not a fork
  **[fork 1.3.10]**: `patches/*.patch`, applied by `scripts/apply_core_patches.sh` before the core is built (`build_and_repack.sh`
  and both workflows; a patch already in is skipped, one that does not apply fails the build).
- The core is built for `aarch64-apple-ios` as a static library, `cbindgen` writes `alvr_client_core.h`, `repack_alvr_client.sh`
  wraps both into the xcframework the Xcode project links.
- `.github/workflows/build.yml` compiles a Debug build; `testflight.yml` archives, signs with an App Store Connect API key and
  uploads (`docs/TESTFLIGHT.md`). No Mac is needed; the CI run is the only compile of the files the harness does not cover.

## 13. Testing without a headset

`tools/protocol-harness/` compiles the real `EventHandler.swift` on Linux against stand-ins for the Apple frameworks, a scripted
client core and streamer (`FakeCore.swift`) and a model of the render loop (`DisplaySim.swift`, which mirrors `renderFrame`'s
protocol calls and must be kept in step with it). It covers sections 5.1 to 5.6 and section 8: stream transitions, stalls, link
loss, decoder death, pacing of the pick, with ThreadSanitizer as an option.

It does not cover Metal, CompositorServices, ARKit, the real VideoToolbox, SwiftUI, or the Rust core itself: `Renderer.swift`,
`MetalClientSystem.swift`, `ALVRClientApp.swift` and `WorldTracker.swift` are checked by the CI compile and on the headset only. A
change to the core can be run for real through the AirFrameXR lab's mock headset, which links the same `client_core`.

## 14. What to keep in mind when changing it

- A new blocking call on the render thread is a new way to freeze the picture: keep sends on the outgoing workers.
- A new piece of state shared between the event, video and render threads goes under `frameQueueLock`, and no core call goes
  inside it.
- A change to `EventHandler.swift` or to the protocol calls of `renderFrame`: run the harness, and update `DisplaySim.swift` when
  `renderFrame` changed.
- A new client-side rule (section 8) needs a scenario, and a `[stream]` line when it fires.
- A change to the client core: a patch in `patches/`, small, with its reason in the patch.
