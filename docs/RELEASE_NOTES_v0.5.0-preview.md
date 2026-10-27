# ZMF THEATERS+ V0.5.0 — HOME 4DX GENESIS (preview) · October 27, 2026

Turns the Windows cinema into the brain of a **real home 4DX room**, using hardware you already own.

## Downloads
- `ZMFTheaters.exe`: single-file Windows 10/11 x64 app (not code-signed; SmartScreen → More info → Run anyway)
- `ZMFTheaters-Windows-x64.zip`: the same app as a portable folder
- `home4dx-tests.txt`, `fourdx-tests.txt`: the CI test logs for this build (mock devices)

## What's new
- **Admin → Immersive Home 4DX** control centre:
  - dashboard and device discovery
  - automatic AI effects, physical configuration and virtual effects
  - lighting, wind controller and private rooms
  - PC + iPhone companion and testing laboratory
  - safety/emergency stop and diagnostics
- **Tapo P125M:** native C# implementation of TP-Link's local KLAP protocol, byte-for-byte checked against python-kasa.
  - UDP discovery, authenticated on/off, status and latency.
  - Credentials encrypted with Windows DPAPI.
  - Switching protection: minimum on/off times, hourly budget, cutoff, deduplication.
  - Command timeouts and reconnects.
- **Wind:** TAPO_01 powers the Sweetfull fan's USB adapter. Automation is enabled **only after the fan restart test passes**. It is ON/OFF only: no speed control.
- **Govee strip:** Bluetooth LE scan, model identification wizard, and community-protocol colour variants that you confirm visually. Keep-alive and reconnect. Unsupported models are reported as such.
- **Scene director:**
  - Uses live picture motion, colour and soundtrack analysis to request wind (sustained scenes only) and a stabilised cinematic light palette.
  - Booms make a bounded warm swell; no strobing.
  - Pause, seek, stop and the end of the film cancel effects.
  - Every decision is a unified `FourDXEvent`, stored as per-title timelines.
- **Private cinema rooms:** local ASP.NET Core host with access-code and invite authentication, chat, seats, playback state and persistence.
- **AI guests:** Nova, Alex, Mia and Jordan, an offline scripted personality engine, always labelled "AI · scripted".
- **iPhone companion:**
  - Safari page (devices, director, playback control, rooms, emergency stop).
  - The iOS app reports phone playback so the PC replays that title's analysed timeline. Titles the PC hasn't analysed get no physical effects.
- **Emergency stop:** header button, F12 in the cinema, the companion and the iPhone app.

## Verification status
- **Software:** Windows build, smoke test, 3D, 4DX and Home 4DX regression tests pass in GitHub Actions. Home 4DX tests use **mock devices only**.
- **Awaiting hardware verification on your equipment:**
  - Tapo discovery and control of your three P125M plugs
  - the Sweetfull fan restart behaviour
  - your Govee model's Bluetooth control and colours
  - movie wind, lightning swell and pause on real devices
  - iPhone sync over your network
  - friends joining from their own devices
- **Not included:** variable fan speed (impossible with a plug), verified TactSuit Air motor mapping (see docs/BHAPTICS_AUDIT.md), and semantic object recognition (scene labels are honest heuristics).

See docs/HOME4DX_SETUP.md, docs/HOME4DX_TROUBLESHOOTING.md and docs/HOME4DX_SAFETY_AND_SECURITY.md.
