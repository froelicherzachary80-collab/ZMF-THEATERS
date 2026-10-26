# Immersive 4DX development status

This branch is an **incomplete foundation**, not v0.4.0-preview and not a release candidate. The production version and published v0.3 assets are unchanged.

## Implemented in source

- Four ticket formats: 2D, Auto 3D, Auto 4DX, Auto 4DX 3D. Combined tickets route through the existing Depth Anything V2 pipeline and the motion engine simultaneously. Existing ticket enum values remain compatible.
- Permanent 4DX availability. October 27–28, 2026 remains the historical preview window; it no longer controls admission.
- Conservative picture-motion output with bounded intensity, a cut holdoff, and playback-time animation. Brightness alone no longer creates impacts, flashes or smoke. This deliberately does not label image changes as explosions.
- Playback discontinuity resets, iOS pause handling, nonfinite-input guards, and automatic neutral return on stop.
- Four-format selectors use two columns so the new choice fits.
- Windows Player transport status no longer claims that a suit is connected. Legacy vest output is disabled pending protocol validation. iOS built-in Taptic feedback is not vest feedback.
- Regression tests on both platforms; Windows depth inference test is a required check. CI produces development artifacts without overwriting any published release.

## Missing acceptance requirements

The full expansion is not delivered: 73 individually implemented effects, multimodal/semantic recognition, audio analysis, optical-flow estimation, event timeline/cache, detailed mechanical seats, dedicated auditorium, advanced particle renderer, spatial-audio library, official bHaptics bridges, device pairing UI, performance monitor, and the 73-effect demonstration lab remain unimplemented.

Current output is gentle procedural camera motion based on a small brightness grid. It cannot reliably infer car chases, rain, punches, blood, explosions, aircraft or other semantic events. No claim of AAA visuals, 60 FPS, source-rate playback, or improved inference speed has been verified. The existing Windows stereo composition still runs on the UI thread.

## Build and test evidence

Use the Actions runs for the exact commit, not an earlier release. Windows builds an executable and portable ZIP; iOS builds an unsigned device IPA, simulator tests and screenshots. CI artifacts are development builds, not a released v0.4 product.

Windows `--selftest-4dx <log-path>` tests cuts/flashes, static frames, bounded motion, backward seeks, stop resets, invalid inputs and format flags. iOS XCTest checks format compatibility, permanent availability, flash rejection and stop behavior. These are algorithmic regression fixtures; they do not validate semantic recognition or real-film accuracy. The existing depth test verifies inference and composition, not subjective stereo quality.

Physical Windows playback, a physical iPhone, Bluetooth pairing, motor layout and actual vest vibration remain unverified. An unsigned IPA requires compatible external signing and provisioning before installation on an iPhone.

## bHaptics investigation

Official Swift guide: https://docs.bhaptics.com/sdk/swift/guide

The official SDK supports direct BLE on iOS. The documented integration uses the `bhaptics-ios` Swift package, a deployed haptic application and app credentials, `NSBluetoothAlwaysUsageDescription`, and device-state callbacks. Simulator compilation does not test Bluetooth. The guide's generic vest example uses TactSuit Pro motor counts; those values must not be asserted to be the TactSuit Air's physical motor layout. The existing legacy 20-dot front/back WebSocket implementation is not validated as a 16-motor Air mapping.

## Release gate

Do not publish `v0.4.0-preview` from this branch until the missing implementation and acceptance tests have been completed. Passing these limited regression tests is insufficient for that release.
