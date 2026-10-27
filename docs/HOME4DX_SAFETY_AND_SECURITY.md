# Home 4DX — safety and security

ZMF THEATERS+ V0.5 can switch real mains power through smart plugs and control a real LED strip. It is designed so that a bug, a crash or a misdetection can't create a dangerous situation.

## Electrical and physical safety

- **Only switch devices that are safe to switch unattended**: the USB fan's adapter, an LED strip's adapter. Never the PC, router, NAS, heaters, cooking appliances, medical equipment or anything that must stay on.
  - Mark such a plug **"powers essential equipment"** and ZMF refuses to switch it.
- **Authorized-device allowlist:** only plugs you explicitly authorize are automated. TAPO_02 and TAPO_03 are never automated until you assign hardware.
- **Respect load ratings.** The P125M's 15 A general rating is not a motor rating, and motor loads must stay well below it. A USB fan adapter is a tiny load.
- **Switching protection:** at least 8 s on, at least 12 s off, at most 30 switches per hour, a continuous-on cutoff (15 min by default), duplicate commands suppressed. There is never frame-by-frame switching. Wind is only for scenes held at least 3 s.
- **Fan automation requires a passed restart test.** ZMF never claims the fan works because the plug is on: a plug's state is not proof that a fan spins.
- **No modifications:** don't open the fan, change its wiring or vary its voltage. ZMF only does ON/OFF.
- **No liquid or mist hardware** near electronics. Rain, mist, smoke and fire in ZMF are **virtual** (drawn on screen). No improvised or mains-powered motion chairs: the moving chair is virtual only.
- **Light safety:** brightness limits per intensity level, smooth transitions, no strobing. "Reduced flashes" is the default and "No flashing" is available. Booms produce a slow warm swell.

## Stopping everything

- **Emergency stop** is available in four places:
  - Home 4DX header and Safety page
  - **F12** in the cinema
  - Safari companion
  - iPhone app
- It cancels scheduled commands, switches every authorized non-essential plug off, sets the strip to dim warm white, and blocks automation until you re-arm.
- Pause, stop, seek, the end of the film, closing ZMF, and "nothing playing" all turn the automated fan off.
- **Manual override always works:** Tapo app, Apple Home, the plug's button, the Govee app, or unplugging. ZMF never locks you out of your devices.

## Network security

- The private-cinema/companion host listens on your **local network only**, port 8977.
- **Every API call needs a token:**
  - The host gets one with the access code: 10 random characters, shown only on the PC, regenerable.
  - Guests get one with a room invite code: 8 random characters, valid for that one room.
- Wrong codes are throttled.
- **Guests can never see or control home devices**, or trigger device commands.
- Real people can't use an AI guest's name.
- Traffic on your LAN is plain HTTP. For anyone outside your home, use an **encrypted overlay such as Tailscale**. **Never forward port 8977 to the internet.**
- **Credentials:** the Tapo e-mail and password and the access code are stored with **Windows DPAPI** (encrypted for your Windows user) in `%APPDATA%\ZMFTheaters\config.json`. The iPhone stores the access code in the **Keychain**.
  - Nothing is uploaded to any cloud by ZMF, and no secrets are in the source code or GitHub.
  - Matter onboarding codes are never requested or stored.
- **Privacy:** room chat is stored locally on the PC (`rooms.json`). The phone reports only the Jellyfin item id, title, position and play state, never video or audio. Film analysis happens on the PC and is saved as small effect timelines.

## Media rights

ZMF synchronises viewers who each play **their own authorised copy** (Jellyfin SyncPlay or similar). It doesn't redistribute films through the rooms. It never extracts frames or audio from DRM-protected services (Netflix, Disney+, YouTube…). Those sources get no automatic physical effects.
