# Home 4DX troubleshooting

| Symptom | What to check |
|---|---|
| **Discovery finds no Tapo plug** | The PC and plugs must be on the same network or VLAN. Guest Wi-Fi or "AP isolation" blocks discovery. Some mesh routers drop UDP broadcasts: enter the plug IP manually (Tapo app → device → ⚙ → Device info). Allow ZMF through Windows Firewall on **private** networks. |
| **"The plug rejected these Tapo account credentials"** | Use the exact e-mail and password of the Tapo account that owns the plug (both case-sensitive). If you recently changed the account password, open the Tapo app once so the plug stays linked to the account. A plug set up **only** through Apple Home/Matter, never in the Tapo app, may not accept KLAP: add it to the Tapo app too. |
| **Plug shows DISCONNECTED after working** | Its IP changed: reserve the IP in your router (DHCP reservation) or run discovery again. ZMF reconnects automatically after failures. |
| **Fan never turns on automatically** | Wind needs four things: (1) **Arm physical effects**, (2) TAPO_01 authorized, (3) **T2 plug test passed** and (4) **fan restart test passed**. It also only starts for sustained motion/air-movement-like scenes (≥3 s), never for single explosions, dialogue or background music. Check **Diagnostics** for "held: cooldown" or "refused" lines. |
| **Fan turns off when I pause or seek** | Intended: pause, stop, seek and the end of the film always switch the fan off. |
| **Fan restart test failed** | The S36 starts switched off after power loss, so a plug cannot start it. See the alternatives in the setup guide (fan with a mechanical switch left ON). |
| **Govee strip not found** | Close the Govee Home app (one Bluetooth connection at a time). Make sure PC Bluetooth is on and the strip is within a few metres. Scan again. |
| **"Govee control service not found"** | Your model or firmware uses a protocol ZMF doesn't support (many newer strips encrypt their Bluetooth commands). Lighting stays virtual-only. |
| **Colour test shows "write accepted" but the strip didn't change** | Try variants A, B and C. If none works, your model is unsupported. Bluetooth accepting a write does not prove the light changed, which is why ZMF asks you. |
| **Strip disconnects during films** | ZMF sends a keep-alive every 2 s and reconnects. Move the PC's Bluetooth adapter closer, or use a USB Bluetooth dongle on an extension cable. |
| **iPhone can't open the companion** | Use the PC's address shown in **PC + iPhone Companion**, with the iPhone on the same Wi-Fi (not cellular). Allow the Windows Firewall prompt for private networks. iOS asks for **Local Network** permission the first time: allow it. |
| **iPhone app says "No analysed 4DX timeline"** | The PC hasn't analysed that title yet. Play it once in Auto 4DX on the PC; the timeline is saved in `%APPDATA%\ZMFTheaters\timelines`. |
| **YouTube shows no physical effects** | YouTube doesn't let apps read its frames or audio, so ZMF disables automatic physical effects there instead of inventing them. Virtual 4DX presentation modes still work. |
| **Port 8977 already in use** | Close the other program, or change `HostPort` in `%APPDATA%\ZMFTheaters\config.json` (in the `Home` section) and restart. |
| **I want to start over** | Delete the `Home` section from `%APPDATA%\ZMFTheaters\config.json` (credentials, plug assignments, test results), `rooms.json` (rooms/chat) and the `timelines` folder. |

Use **Diagnostics → Export diagnostics** to save a report to your desktop. Passwords and codes are never included.
