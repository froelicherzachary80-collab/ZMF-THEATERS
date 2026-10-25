# 3D conversion and the 4DX preview

## 2D or 3D for every ticket

When you buy a ticket (iPhone box office or Windows in-world box office), pick a format:

| Format | What happens |
|---|---|
| **2D** | The film plays exactly as mastered. |
| **3D (red/cyan)** | **ZMF DepthCinema AI** converts the film live. You need red/cyan glasses, red over the left eye. |
| **4DX Preview** | Motion seat and effects. Available October 27–28, 2026 only. |

### How the 3D conversion works

1. **Depth estimation.** Decoded frames are sent to **Depth Anything V2 Small**, a monocular depth model.
   - iPhone: Apple's Core ML build runs on the Neural Engine. It is bundled in the IPA.
   - Windows: the ONNX build runs on your GPU through DirectML, falling back to the CPU. It is about 99 MB and is downloaded once to `%APPDATA%\ZMFTheaters\models`.
2. **Stabilisation.** Each depth map is normalised with a slowly moving min/max and blended with the previous map, so depth doesn't pump between shots.
3. **View synthesis.** Each eye's view is the frame shifted horizontally by a disparity proportional to (depth − convergence). Depth is dilated around edges so foreground objects don't tear.
4. **Anaglyph.** The left view feeds the red channel and the right view feeds green and blue. "Ghosting reduction" blends toward an optimised red channel that reduces crosstalk.

The depth model runs a few times per second; you can choose 4, 8, 15 or 30 Hz. Frames in between reuse the stabilised map, so the film itself always plays at full frame rate.

Converted 3D *approximates* depth from a single image. It is not the same as a film mastered in native stereo 3D.

**Tuning (iPhone: Admin → 3D Cinema Settings):**

| Setting | What it does |
|---|---|
| Depth intensity | Overall 3D strength. |
| Stereo separation | Maximum disparity. |
| Convergence | Which depth sits exactly on the screen plane. |
| Ghosting reduction | How much the red channel is optimised to reduce crosstalk. |
| Performance preset | How often the depth model runs. |

## ZMF 4DX preview: October 27–28, 2026

During the two preview days (New York time), the **4DX Preview** format appears at the box office for Z$400. Effects are driven live by the picture:

| On screen | Effect |
|---|---|
| Sustained action and motion | Motion-seat sway and rumble |
| Sudden flashes and explosions | Strobe, a seat kick, a smoke burst, and a haptic impact |
| Hard scene cuts | Ignored, so a cut doesn't feel like an explosion |

**iPhone:** the Taptic Engine provides the rumble and impacts. bHaptics has no iOS SDK, so the TactSuit can't be driven from iPhone.

**Windows with a bHaptics TactSuit Air:**

1. Install **bHaptics Player** for Windows, turn on the TactSuit Air, and pair it in bHaptics Player.
2. Keep bHaptics Player running.
3. Buy a 4DX ticket in ZMF THEATERS+ for Windows and sit down. The status line shows `TactSuit Air: connected via bHaptics Player`.
4. The vest rumbles front and back with on-screen motion. Impacts hit the chest motors.

To try 4DX outside the preview days, tick **Enable 4DX now (testing)**. On Windows it's in the sidebar; on iPhone it's under Admin → 4DX Preview.
