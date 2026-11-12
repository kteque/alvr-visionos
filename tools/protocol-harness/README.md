# Protocol harness (Linux, no Mac)

Runs the client's **real** `ALVRClient/EventHandler.swift` (event loop, NAL callback, decoder lifecycle, frame queue, the
render thread's frame pick `pollFrameForDisplay`) against a scripted streamer, on Linux with a Swift toolchain. It is
for stream *transitions*: nothing to a game, stalls, choking games, fps drops, encoder rebuilds, stream restarts, and the
app being backgrounded. It needs no Mac, no Xcode and no headset.

```
tools/protocol-harness/build.sh [--tsan]          # build/protocol_harness[_tsan]
tools/protocol-harness/run.sh [--tsan] [name...]  # every scenario by default; one line per scenario, exit = number failed
build/protocol_harness list
build/protocol_harness run <name> --out DIR [--echo]
```

`HARNESS_CORE_STOCK=1` models stock client_core, which sends the statistics packet while it holds its statistics mutex
(`core_block_2s` then fails: the render thread waits behind it). The default models the core as the app builds it, with
`patches/client_core-statistics-send-outside-lock.patch`. Both are models in `FakeCore.swift`: the harness does not run the Rust code.

From the AirFrameXR repository: `python3 harness/stability/run_stability.py client [--tsan] [name...]`.

Toolchain: Swift 6.x for Linux from swift.org. The Ubuntu 24.04 tarball works on Arch once `libncurses.so.6` points at
`libncursesw.so.6`; set `SWIFTC` or put a `swiftc-linux` wrapper on the PATH.

## What is real and what is modelled

| Part | Source |
|---|---|
| Event thread, `handleNals`, decoder create/rebuild, timers, `exit` paths, `OutgoingWorker` | `ALVRClient/EventHandler.swift`, compiled unchanged |
| Apple frameworks (VideoToolbox, UIKit, Network, AVKit, Combine, simd, QuartzCore) | `Shims/AppleShims.swift`: inert stand-ins. `UIApplication.applicationState` can be scripted. |
| client_core C API | `Harness/FakeCore.swift`, exported under the real names from `CAlvr/alvr_client_core.h` (cbindgen output, same command as `build_and_repack.sh:29`). The video receive thread follows `client_core/src/connection.rs:317-367`: IDR, loss and decoder-saturation handling, and the 10-packet unread cap. `report_fatal_decoder_error` leads to a reconnect. |
| Streamer | A script in `Harness/main.swift`. Idle frames run at 30 fps. Game cadence, pose age and jitter are set per scenario. A stall sends nothing. The next frame after an IDR request is an IDR, and DecoderConfig is re-sent with every IDR. Encoder rebuild and stream restart are also modelled. |
| Decoder | `VideoHandler` stand-in in `Harness/AppStubs.swift`. Decoding is synchronous on the core's thread, like VideoToolbox with flags 0. A P frame fails when its reference was not decoded, when its config differs from the session's, or when the session is invalidated. |
| Render thread | `Harness/DisplaySim.swift`. It ticks at 90 Hz and calls the client's `pollFrameForDisplay`, `publishShownFrame` and `markSubmitted`. The rest mirrors `Renderer.renderFrame`'s protocol calls line by line, without Metal. |

Each verdict comes from what the wearer would have seen at each display tick: a new frame, a repeated frame, or nothing.
The verdict fails if fewer than 80 % of ticks show a new frame from one second after the last transition, if the client
reconnects on its own, or if it calls `exit()` when it should not. `--tsan` adds ThreadSanitizer: the `races` column counts
its reports. Read the `.tsan.*` files for the two stacks.

## The display-rate switch scenarios (`sw_*`)

The system can change the display rate (90 / 96 / 100 Hz) with a render stall; the host follows with a new stream rate. The scenarios assert what the **client** owns: after the first
switch the picture is never stuck for more than 3 ticks in a row (seen: at most 1), and from 3 s on at most 2 % of the ticks repeat (seen: at most 0.1 %).

They do **not** assert the age of the frames shown (host send to display tick). It is recorded (`age_*`, `depth_*` in the verdict) but it cannot be a pass/fail number here: it is the phase
between the scripted stream and the display ticks, plus a standing second decoded frame in the queue. The shipped pick (`catchUpPick` off, 8 ms wait) never drops a fresh frame, so a queue of 2
that forms after a stall, or at the start, never drains while the stream rate equals the display rate: queue depth 2 and an age of 15 to 25 ms in most runs, against depth 1 and 5 to 13 ms with the
catch-up rule on (`HARNESS_CATCHUP_PICK=1`). Before 2026-11-12 these scenarios asserted an age of at most 14 ms, which only the catch-up pick could keep; the absolute value also moves with the
display rate (100 Hz is the standard now) and a delta against the pre-switch age is no better (+0 to +14 ms in repeated runs of the same scenario), so both were dropped.

In the real chain the host's phase lock watches the client's decoder-queue time and slides its frame clock to bring the queue back to one frame; this harness has no host lock, so the standing
queue is the client's behaviour **without** it. Whether the lock removes it quickly enough on a headset after a display switch is not measured here (the lab's `e2e_*` chain scenarios and the
headset are where to look). A catch-up that only acts on a queue that has stayed at 2 for a while (not on every jitter) would keep the 1.3.9 benefit and remove the standing frame; it is not built and not measured on a headset.

**Not tested on a real headset:** switches to or from 96 Hz, and rapid back-and-forth switching (`sw_rapid`).

## Limits

- Swift on Linux is not Swift on visionOS. The compiled file is the same, but the threads, scheduler and memory model
  differ, so a clean TSan run only says the harness found no race. It does not prove there is none.
- Nothing about Metal, CompositorServices, ARKit or the real VideoToolbox is exercised: pipeline rebuilds, layer
  invalidation, decode timing and how VideoToolbox reacts to a broken reference chain are all modelled or absent.
- The scripted IDR is instant and lossless. A real IDR is large and takes time, so recovery times here are lower bounds.
- When `EventHandler.swift` or `Renderer.renderFrame` changes, update the mirrored lines in the harness
  (`DisplaySim.swift` names the line ranges).
