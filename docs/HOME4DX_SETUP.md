# Home 4DX setup guide (V0.5.0 — HOME 4DX GENESIS)

This guide sets up ZMF THEATERS+ Home 4DX with the hardware you already own:

- **3 × TP-Link Tapo Mini Smart Wi-Fi Plug (P125M)**
- **Sweetfull S36 USB desk fan**
- **Govee RGBIC LED strip** (Bluetooth; exact model to be identified)
- **iPhone 16 Pro** as a companion

The Windows PC is the "4DX brain". It analyses the film, decides on effects, and sends commands to the plugs and the strip. The iPhone can watch, control playback, chat in private rooms, and trigger the emergency stop.

> **Nothing here was tested on your physical devices during development.** Every physical feature stays *awaiting hardware verification* until you run the matching test in **Admin → Immersive Home 4DX → Testing Laboratory**.

---

## 1. Install the Windows program

1. Download `ZMFTheaters.exe` (single file) or `ZMFTheaters-Windows-x64.zip` (portable folder) from the `v0.5.0-preview` release.
2. Run it. Windows SmartScreen may warn because the exe is not code-signed: choose **More info → Run anyway**.
3. The first time it starts, Windows asks whether ZMF THEATERS+ may accept network connections. **Allow it for private networks only.** The iPhone companion and private rooms need this. Don't allow public networks.
4. To open the Home 4DX control centre: **Admin** (left menu) → **Open Immersive Home 4DX**.

Requirements:
- Windows 10 (version 2004 or later) or Windows 11, 64-bit.
- Microsoft Edge WebView2 Runtime, which Windows 10/11 already include.
- Bluetooth LE for the Govee strip.
- No NVIDIA GPU needed. Analysis runs on the CPU, and 3D conversion uses DirectML or the CPU.

## 2. Set up the three Tapo P125M plugs

1. Install the **Tapo** app on your iPhone and sign in to (or create) your TP-Link account.
2. Tapo P125M plugs only use **2.4 GHz Wi-Fi**. If your router combines 2.4 and 5 GHz under one name and setup fails, temporarily enable a separate 2.4 GHz network in the router, or stand closer to it.
3. In the Tapo app: **+ → Plugs → P125M** and follow the steps for each plug. Name them, for example "ZMF Wind", "ZMF Aux" and "ZMF Future".
4. Keep each plug in the Tapo app even if you also add it to Apple Home via Matter. ZMF talks to the plug over your local network with the same protocol python-kasa uses ("KLAP"). That protocol authenticates with your **Tapo account e-mail and password**.
5. On the PC: **Home 4DX → Smart Device Discovery**:
   1. Enter your Tapo e-mail and password and click **Save credentials**. They are stored encrypted with Windows DPAPI for your Windows user only. They are never uploaded or committed anywhere.
   2. Click **Discover Tapo plugs**. Each P125M should appear with its IP and MAC address.
   3. Assign the plugs:
      - **→ TAPO_01** for the fan plug (role MAIN_WIND)
      - **→ TAPO_02** (AUXILIARY_EFFECT)
      - **→ TAPO_03** (FUTURE_EFFECT)
   4. If discovery finds nothing (some routers block broadcasts), type each plug's IP address in **Manual address** and click **Connect**. The Tapo app shows the IP under *Device info*.
6. Each plug now shows **CONNECTED — UNVERIFIED OUTPUT** until you run the tests in step 4.

> **TAPO_02 and TAPO_03 stay unassigned** and are never switched automatically. A smart plug can only switch power on and off. It cannot change fan speed, LED colour or motor behaviour.

## 3. Attach the Sweetfull S36 fan

1. Plug a **USB wall adapter** into **TAPO_01**. Use a reputable 5 V adapter, at least 1 A. Plug the fan's USB cable into the adapter.
2. Aim the fan at your seat with its tilt hinge.
3. Pick your preferred speed with the fan's button. A plug cannot change the speed, so whatever you pick is the "4DX wind" level.
4. Don't open, rewire or modify the fan, and don't feed it any voltage other than its USB supply.

## 4. Test whether the fan restarts after power returns (important)

Many single-button USB fans **start switched off** when power returns. If yours does, a smart plug **cannot** start it, and automatic wind stays disabled.

1. **Physical Effect Configuration** → TAPO_01 → tick **Authorize this plug for ZMF control**. Make sure it only powers the fan's USB adapter.
2. **Testing Laboratory → T2 Plug control**. Confirm the prompt. The plug switches ON for 3 s then OFF, and ZMF checks the plug's reported state each time.
3. **Wind Controller → Run fan restart test** (or **T3** in the lab):
   1. ZMF switches the plug ON. Start the fan with its button and confirm.
   2. Allow the 5-second power cut.
   3. When power returns, answer honestly whether the fan **started spinning by itself**.
4. **If yes:** the result is saved, TAPO_01 shows **CONNECTED — TESTED**, and automatic wind can be armed.
5. **If no:** automatic wind stays **disabled**, and ZMF will never claim fan automation works. Compatible alternatives:
   - A USB or desk fan with a **mechanical slide or rocker switch** that you leave ON, so it runs whenever powered.
   - A fan whose manual states it **resumes after power loss**.

## 5. Find your Govee model number

You need the **H-number**, for example H6163, H619A or H6143. Look in any of these places:

- the **label on the small controller box** or power adapter on the strip's cable
- the **product box**, or the sticker on the reel
- the **Govee Home app**: tap the strip → ⚙ settings → **Device info → Model**

The Bluetooth name often contains it too, e.g. `ihoment_H6163_A1B2`. ZMF shows that name after scanning.

## 6. Pair the Govee strip and enable colour control (if supported)

Govee publishes **no official local Bluetooth API**, and its cloud developer API does not generally control Bluetooth-only strips. ZMF uses packet formats documented by community reverse-engineering projects. They differ between models, and newer firmware may use an encrypted protocol that ZMF **cannot** control.

1. Make sure the strip is powered and PC Bluetooth is on. **Close the Govee Home app on your phone**, because a strip accepts only one Bluetooth connection at a time.
2. **Smart Device Discovery → Scan Bluetooth** → **Use this strip**.
3. **Lighting and Color Control**:
   1. Type the H-number and click **Confirm model**.
   2. Click **Connect via Bluetooth**.
   3. Click **Test A**. The strip should go blue → green → red. Answer whether you saw it.
   4. If nothing changed, try **Test B**, then **Test C**.
   5. When one works, ZMF saves that protocol, marks the strip **CONNECTED — TESTED**, and you can tick **Authorize automatic lighting**.
4. If **no test changes the strip**, your model is not supported by the community protocol. The strip stays **UNSUPPORTED**, and the lighting director only tints the virtual auditorium. Control the strip with the Govee app as usual.

A Tapo plug may switch the strip's power adapter if that is electrically appropriate. That only turns it on or off; it is not colour control.

## 7. Turn on automatic effects

**Automatic AI Effects**:
1. Tick **Arm physical effects**. Until you do, ZMF only *shows* its decisions.
2. Choose an intensity: **Gentle / Standard / Intense / Extreme**. All levels are bounded.
3. Choose a flash setting: **Normal**, **Reduced flashes** (default) or **No flashing**.
4. **Virtual-only mode** disables every physical command.

Then buy an **Auto 4DX** or **Auto 4DX 3D** ticket in the cinema and play a film from your Jellyfin server.
- **Wind:** the fan turns on for sustained motion or air-movement-like scenes, held for at least 3 s, with cooldowns.
- **Lights:** the strip follows a stabilised cinematic palette, such as ocean, forest, fire, night or warm indoor.
- **Explosions:** a sound-detected boom makes the strip swell gently, never strobe.
- **Dialogue:** keeps the room calm.

## 8. Connect your iPhone

**PC + iPhone Companion** shows the **access code** and the addresses, e.g. `http://192.168.1.20:8977/companion`.

- **Safari companion** (no install): open the address on the iPhone, sign in with the code, then **Share → Add to Home Screen**. It shows device states, the scene director, last commands, playback controls, private rooms with chat, and a big **EMERGENCY STOP** button.
- **ZMF THEATERS+ iPhone app**: **Admin → Server Manager → Home 4DX (Windows PC)**. Enter the PC address and code, then tap **Connect**. While a film plays on the phone, the PC replays the 4DX timeline it **analysed for that title** and drives the fan and lights.
  - Titles the PC has never analysed get **no** physical effects. Play them once in Auto 4DX on the PC first.

## 9. Host a private cinema room and invite friends

1. **Private Cinema Rooms → Create room** (or create one in the Safari companion).
2. **Copy invite link** and send it to a friend. They open it, type their name and join; they get a seat and the room chat.
3. Guests see the room's film, position and play state. Each guest plays **their own authorised copy** (e.g. from your Jellyfin via a **Watch Party**, which uses Jellyfin SyncPlay, or their own source). ZMF never streams your films to them through the room.
4. Guests **cannot** see or control your home devices.
5. **Friends outside your home:** don't forward port 8977 on your router. Install **Tailscale** (free for personal use) on the PC and your friend's device, share the PC with them, and send the invite link using the PC's Tailscale name. The connection is then encrypted end to end.

## 10. Add AI guests

In a room, click **+ Nova / + Alex / + Mia / + Jordan (AI)**:

| Guest | Personality |
|---|---|
| Nova | enthusiastic movie fan |
| Alex | action and science-fiction fan |
| Mia | fantasy and romance fan |
| Jordan | horror and suspense fan |

- They take seats, appear next to you in the 3D auditorium with an **AI** name tag, greet you and answer chat messages.
- They react to big detected moments, at most one reaction per 20 s, and keep quiet or whisper during dialogue-like scenes.
- They are **scripted personalities** from an offline rule-based engine, not a language model, and are always labelled **AI · scripted**.

## 11. Run the Testing Laboratory

**Testing Laboratory** lists 12 tests. Physical tests need your devices and your confirmation:

| Test | What it checks |
|---|---|
| T1 | Tapo discovery: finds your three P125M plugs |
| T2 | Plug control: on/off confirmed by each plug's reported state |
| T3 | Fan restart (see step 4) |
| T4 | Govee discovery: finds the strip and its model |
| T5 | Govee colour: blue/green/red, confirmed by you |
| T6 | Movie wind: play an Auto 4DX film with a sustained motion scene; the lab waits for a real fan ON acknowledgement and asks if you felt it |
| T7 | Lightning: a smooth brightness swell, no rapid flashing |
| T8 | Pause: pause during wind; the fan must turn off immediately |
| T9 | Phone sync: play a film on the iPhone with the app connected |
| T10 | Private cinema: a friend joins with an invite |
| T11 | AI guest: Nova joins and replies |
| T12 | Emergency stop: every authorized plug reports OFF |

**Run mock self-test** runs the software tests against simulated devices. Its results are labelled MOCK and never count as physical verification.

## 12. Turn off every automated effect

- **EMERGENCY STOP** is always available:
  - the red button at the top of Home 4DX
  - **F12** in the cinema
  - the Safari companion
  - the iPhone app (Server Manager → Home 4DX)
- It cancels scheduled commands, switches every authorized plug **off**, sets the strip to dim warm white, and blocks automation until you click **Re-arm**.
- **Virtual-only mode** or unticking **Arm physical effects** stops physical commands permanently.
- If ZMF is closed or crashed, use the **Tapo app**, **Apple Home**, the plug's own button, the **Govee app**, or simply unplug the device.


## V0.5.1 — Tapo power-source automation (2026-10-27)

This update starts from successful iOS workflow run [40477918617](https://github.com/froelicherzachary80-collab/ZMF-THEATERS/actions/runs/40477918617) on branch `feature/v0.5.0-home-4dx-genesis` (commit `c2507cdf`). Both platforms are built by their existing GitHub Actions workflows; the iOS artifact is **unsigned** (install with a legitimate signing/sideloading method). CI has no physical smart plugs or lights and cannot verify your real hardware.

### Power chain — supported equipment

1. **TAPO_01 = MAIN_WIND:** approved Sweetfull fan USB adapter ONLY. Verify power loss/recovery physically; many USB button fans **do not** auto-restart, so power-only automation might not work. Plug switch means **on/off**, not speed control.
2. **TAPO_02 = GOVEE_POWER:** Govee RGBIC LED strip's *approved* wall adapter ONLY. Pair strip's Bluetooth directly to the Windows PC in **Smart Device Discovery**, confirm H-model and run the **BLUE → GREEN → RED** colour test. Run the **Govee power restoration** wizard. Only after the plug test, power-restoration test, authorizations and BLE colour test pass can the director power the strip on and send colour/brightness commands. Do not assume all RGBIC models support this community-documented Bluetooth protocol; RGBIC segments require a validated protocol.
3. **TAPO_03 = FUTURE_EFFECT:** reserved; never driven by the automatic director in this version.

In Windows: **Admin → Immersive Home 4DX** → Discover and configure the three Tapo slots → mark any plug powering essential equipment as Essential → authorize individual compatible devices → run T2 plug control tests → run T3 Sweetfull restart test and new T13 Govee restoration test → configure and confirm Govee colour protocol → arm Physical Effects. Launch an Auto 4DX screening with decodable picture/sound. The PC runs analysis, Tapo KLAP local power commands and Govee Bluetooth; the iPhone app reports the same title's playback position and displays a read-only status for Tapo / Govee, with emergency stop. Playback on iPhone requires the PC to have recorded a title timeline previously; unsupported web streams cannot magically produce hardware scene-analysis signals.

**Safety / limits:** Tapo controls **mains power**, not arbitrary voltage, dimming or motor speed. Confirm load and adapter ratings. No PC, router, medical device, heater or other essential load on automated plugs. Govee needs a 3-second reboot window before BLE colour writes after plug ON. Light source is power-gated at minimum 30 seconds on, 60 seconds off, 10 switches/hour, 4 hours continuous ON. Fan has separate minimum 8 seconds on, 12 seconds off and 30 switches/hour. Pause/stop/connection loss removes power from both authorized effects; manual override in manufacturer apps is always possible. If Windows crashes or home Wi-Fi drops, software OFF is not guaranteed; use the physical plug button or Tapo app immediately. No rapid strobes, hot elements, homemade mains modifications or unsupervised liquid/mist hardware.

For **testing**: CI's simulated end-to-end power-chain checks are always labelled MOCK. On your real equipment the Windows **Testing Laboratory** requires explicit physical confirmation; only then display CONNECTED—TESTED.

### No RGBIC Bluetooth control on your strip?

In **Lighting and Color Control**, choose **Use Tapo power-only lighting**. Once the Tapo plug passes its control and Govee power-restoration tests, the strip powers on for analysed playback and off for pause/stop. This does **not** automatically change the colours scene-by-scene. Disable power-only mode only if the Govee colour wizard visibly validates the specific model and its BLE protocol. The PC retries a previously verified BLE connection after source power recovers, rather than silently claiming that lights changed.
