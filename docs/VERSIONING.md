# Version numbers

**The app version (CFBundleShortVersionString) is a compatibility version, not a release counter.** It stays the same
for as long as the client speaks the same protocol as the streamer, and only changes when compatibility breaks.
Apple reviews a *version*: new builds under a version already approved or in review need no new App Review (builds of an approved version
usually reach external TestFlight testers without a new Beta App Review; Apple decides).

- Current compatibility version: **1.4.1** = ALVR v20 protocol (v20.14.1 core), the version submitted to App Review.
- Every fix or feature that keeps the v20 protocol ships as a **new build number** (the workflow's run number, always
  going up) under the same version. Streamers and clients of any build of 1.4.1 work together.
- Change the version only when an old client and a new streamer (or the reverse) can no longer talk: ALVR v21, a
  changed control or video header. Then pick the next number (1.5.0), say so in the release notes, and submit it.
- What the user sees as "the version" of a feature is the streamer's release (AirFrameXR 1.4.x); the client's build
  number says which client code runs.

Workflows: `testflight.yml` input `marketing_version` and `appstore.yml` input `version` default to the current
compatibility version. Leave them alone for normal builds.
