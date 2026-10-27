# bHaptics TactSuit Air: integration audit (V0.5)

The TactSuit Air is **not** part of the confirmed October 27 equipment. Home 4DX works fully without it.

## What the existing code does

- `windows/ZMFTheaters.Windows/Cinema/FourDX.cs` → `BHapticsClient`:
  - Talks to **bHaptics Player** through the **legacy local WebSocket API** (`ws://127.0.0.1:15881/v2/feedbacks`, the tact-js "Submit/frame" format).
  - Addresses the vest with **20 dot indices per side** (`VestFront` / `VestBack`, 4 columns × 5 rows). That is the **TactSuit X40 layout**.
  - Sends rumble frames and per-event patterns:
    - boom = whole vest
    - sharp hit = chest indices 5, 6, 9, 10
    - debris = random dots

## Audit findings

1. **Layout mismatch risk.** The TactSuit Air has **16 motors**. The 20-per-side indices above assume the 40-motor X40. Whether bHaptics Player remaps X40 dot indices onto the Air's motors (and how) is **not verified**.
   - The official motor-index reference (https://docs.bhaptics.com/sdk/further/motor) is rendered by JavaScript and could not be loaded in this build environment, so **no Air index table was copied or assumed**.
2. **Protocol age.** The current bHaptics SDK (SDK2, via bHaptics Hub/Player) registers apps with an **App ID and API key** from the bHaptics developer portal. The legacy v2 WebSocket endpoint may not be available in newer Player builds.
3. **Safety controls present:**
   - output is **opt-in** (`OutputEnabled = false` by default)
   - writes are rate-limited (≥ 90 ms) with 250 ms timeouts
   - a failed send disables output
   - the Home 4DX **emergency stop now also disables suit output**

## Before claiming TactSuit Air support

- [ ] Register ZMF on the bHaptics developer portal and switch to the official SDK2 path (App ID / API key, kept out of source control).
- [ ] Take the Air's motor indices from the official motor page, not from the X40 grid, and map ZMF's front/back directional events to them.
- [ ] Add a hardware test (front-left / front-right / back pulses confirmed by the wearer) to the Testing Laboratory.
- [ ] Add a per-suit intensity setting and keep the emergency stop wired in.

Until then, TactSuit output is labelled **awaiting hardware verification**.
