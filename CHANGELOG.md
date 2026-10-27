# Changelog

## 0.5.0-preview: HOME 4DX GENESIS (2026-10-27)

### Added
- **Immersive Home 4DX** (Windows, Admin → Immersive Home 4DX). It has 12 sections: dashboard, device discovery, automatic AI effects, physical configuration, virtual effects, lighting, wind, private rooms, PC + iPhone companion, testing laboratory, safety/emergency stop and diagnostics.
  - Device states are explicit: CONNECTED — TESTED, CONNECTED — UNVERIFIED OUTPUT, DISCONNECTED, SIMULATED, UNSUPPORTED.
- **Tapo P125M control:**
  - A native implementation of TP-Link's local KLAP protocol: handshake, AES session and signed sequence numbers. It is checked byte-for-byte against python-kasa 0.12.0 reference vectors.
  - UDP discovery on port 20002, on/off with the plug's reported state as acknowledgement, latency, and reconnects.
  - Credentials are stored with DPAPI.
- **Power gate:**
  - minimum on/off times, an hourly switch budget, a continuous-on cutoff, deduplication
  - an allowlist, and an "essential equipment" lock
- **Fan restart test:** wind automation only after the user confirms the fan resumes after power returns.
- **Govee Bluetooth LE:**
  - scan, model from the advertised name, and a model-identification wizard
  - community colour-protocol variants confirmed visually by the user
  - keep-alive and reconnect, and an explicit UNSUPPORTED outcome
- **Scene director:**
  - Uses live picture and sound analysis for wind, for a stabilised palette (ocean, forest, fire, night, horror, sunset, sci-fi, fantasy, romance, warm indoor) and for bounded blast swells.
  - Has gentle/standard/intense/extreme levels, flash policies and a virtual-only mode.
  - Uses a unified `FourDXEvent` and saves per-title effect timelines.
- **Private cinema rooms:**
  - a local ASP.NET Core host with access-code/invite tokens and throttling
  - rooms, chat, seats, playback state and persistence
  - AI guests (Nova, Alex, Mia, Jordan), scripted and labelled
- **iPhone companion:** a Safari web app, plus a Home 4DX link in the iOS app's Server Manager that reports playback so the PC can replay analysed timelines.
- **Emergency stop** everywhere. The fan turns off on pause, seek, stop, end of film, "nothing playing" and app exit.
- AI guests sit next to you in the Windows auditorium, and the room lighting mirrors the director's palette.
- **CI:**
  - a `--selftest-home` mock-device suite and Control Center screenshots
  - a tag-gated release workflow that publishes only after the build and tests pass
- **Docs:** setup guide, troubleshooting, safety and security, and the bHaptics audit.

### Notes
- Physical features await verification with your own hardware.
- No variable fan speed.
- Scene labels are heuristics, not object recognition.
- YouTube and other unanalysable sources get no automatic physical effects.


## Unreleased: Real-time 4DX from the film (2026-10-27)

### Added
- **Real-time chair motion from the picture** (iPhone and Windows). The camera motion is tracked on a 32×18 luminance grid (9× more cells than the old 8×8 grid) with sub-cell precision:
  - pans bank the chair
  - tilts pitch it
  - push-ins and pull-outs surge it
  - camera roll rolls it
  - handheld shake vibrates it
- **At 100% intensity the chair is very motion-sensitive**: about 3× the 50% response, faster and with wider travel. The intensity slider is now "Intensity & motion sensitivity" (Windows: Presentations → Real-time 4DX).
- **Real-time soundtrack events**:
  - **Sharp hits** (stab / punch / gunshot-like), **booms** (explosion-like blasts, stronger when the picture flashes at the same moment) and **debris** (the crackle after a boom).
  - Music beats, dialogue and steady engine noise are ignored.
  - iPhone reads the film's own audio (direct-play files). Windows listens to the PC's audio output.
- **Better phone haptics**: a hard double strike for hits, a heavy thump with a rolling decay for booms, an uneven patter for debris, and a stronger continuous rumble.
- **TactSuit Air event patterns** (Windows): booms fill the vest front and back, hits are a tight chest strike, debris is a scatter of dots.
- **More virtual effects**:
  - a refracting shockwave ring
  - embers drifting up the view and through the auditorium
  - smoke haze that lingers after blasts
  - debris fragments and hot sparks flung outward
  - a vignette snap on hits
  - spring-damped seat jolts
  - camera roll on Windows

### Notes
- Sounds are classified acoustically, so a stab and a punch feel alike. There is no scene understanding.
- Brightness alone never creates an effect.
- Transcoded (HLS) streams on iPhone don't expose audio, so they use picture motion only.

## 0.4.2: Roller-coaster intro, 4DX screen effects, YouTube presentations, recline fix (2026-10-27)

### Added
- **ZMF THEATERS roller-coaster intro** (iPhone and Windows). An original first-person ride (~49 s) plays on the auditorium screen before the feature: station, ADMIT ONE arch, lift hill, first drop, banked turns through film-reel rings, past giant popcorn buckets, a splash tunnel and a final rise onto the ZMF THEATERS marquee with fireworks.
  - Physics-based speed with banking, so the ride is deterministic and the 4DX seat never drifts from the picture.
  - The announcer (system voice) says "Welcome to ZMF Theaters…" and ends with "ZMF Theaters. Sit back, relax, and enjoy the show."
  - 4DX tickets: the virtual seat pitches, banks and surges with the ride, with wind at speed, water spray in the splash tunnel and rumble on the chain lift.
  - iPhone 3D tickets get true stereo red/cyan (two rendered eyes).
  - Toggles: roller-coaster intro and announcer voice.
- **4DX screen layer**: water droplets that bead and drain, mist haze, wind streaks and vibration over your view while seated. Light flashes are opt-in (off by default).
- **YouTube presentations** before the feature in **2D, 3D, 4DX or 4DX + 3D**. iPhone: Trailer & Preshow Manager. Windows: the new Presentations page (WebView2).
  - 4DX presentations move the virtual seat with the player clock and add wind and water mist.
  - 3D is a red/cyan stereo window: YouTube does not let apps read its pixels, so this is not the AI depth conversion used for your films.
  - The YouTube cinema browser also has the four formats.
- **Premium recliner seats**: upholstered cushions, channel-tufted backrest, wing bolsters, headrest, padded armrests with chrome trim, lit cupholders, and 4DX air/water jets on the seat backs.
- **Recline on Windows**: press R or use the Recline button.

### Fixed
- **Recline showed only red**: on iPhone the reclined camera moved inside the seat's backrest. Recline now tilts your head back and lowers it, staying in front of the upholstery (both apps).
- **YouTube error 152**: the iPhone player now identifies the app's own origin. If the uploader blocks embedding, the video opens on YouTube's watch page with 4DX timing intact.
- iPhone world building no longer copies vertex batches on every quad (launch hang with detailed geometry).

## 0.3.0: Real 3D conversion, Windows 3D cinema, 4DX teaser (2026-10-25)

### Added
- **Choose 2D or 3D for every ticket** (iPhone and Windows). 2D plays exactly as mastered. 3D runs **ZMF DepthCinema AI**: monocular depth with **Depth Anything V2 Small**, then normalisation with a smoothed range, temporal stabilisation, edge-aware depth dilation, depth-image-based left/right view synthesis, and an optimised red/cyan anaglyph with adjustable ghosting reduction.
  - iPhone: Apple's Core ML model runs on the Neural Engine through Vision, and the stereo synthesis runs in a Metal compute kernel.
  - Windows: the ONNX model runs on DirectML (any DX12 GPU, with a CPU fallback). It is downloaded once to `%APPDATA%`.
  - Settings: depth intensity, stereo separation, convergence, ghosting reduction, and performance presets for the depth update rate.
- **Windows: a walkable 3D cinema** (WPF 3D). It has the lobby (marquee, Now Showing posters, box office, concessions, kiosks, 4DX teaser) and the hall with 12 sliding doors. Each of the 12 themed auditoriums has stadium seating, a screen, curtains and sconces. Buy tickets at the in-world box office with a seat map. A guidance arrow leads to your seat. Doors only open with a ticket. Sitting starts the preshow, the house lights dim, and the film plays on the in-world screen with light spill. There is also a fullscreen picture mode and auto-hiding controls.
- **ZMF 4DX preview teaser for October 27–28, 2026**:
  - Pick the 4DX format: Z$400.
  - Motion seat, rumble, strobes and smoke bursts are driven by motion and brightness analysis of the picture.
  - iPhone: Taptic Engine rumble and impacts.
  - Windows: **bHaptics TactSuit Air** through bHaptics Player's local WebSocket API.
  - Teaser posters appear in the lobby and on the title screens.
  - Admin "Enable 4DX now" switch for testing.
- CI downloads the Core ML depth model into the iPhone build. It also runs a headless ONNX 3D self-test on Windows and screenshots both cinemas.

### Changed
- Admin → 3D Cinema Settings is now a working panel instead of a "planned" placeholder.
- The Windows theater window is replaced by the 3D cinema.

## 0.2.0: Immersion, watch parties and Windows (2026-10-24)

### Added
- **Cinema-mode controls (iPhone):** while seated during a screening, the controls fade away after a few seconds. Tap the screen, or the small corner button, to bring them back. Subtitles stay visible. Can be turned off in Admin → Graphics & Controls.
- **HDR rendering pipeline:** an rgba16Float scene target, quarter-resolution bloom with a separable blur, ACES tone mapping, vignette and film grain.
- **Projector beam:** a beam from a projection booth with a real lens, tinted by the picture, with drifting dust motes.
- **More detail in every auditorium:** a curved screen, acoustic wall panels, headrests, lit cupholders and under-seat LEDs.
- **Seated feel:** subtle breathing sway, an adjustable seated field of view, and your popcorn and drink on the armrest.
- **Online watch parties via Jellyfin SyncPlay:** host or join, NTP-style server clock sync, drift correction, a party activity feed, and friends drawn as seated avatars with name tags.
- **ZMF THEATERS+ for Windows 10/11** (`ZMFTheaters.exe`): a native WPF app with LibVLC playback (no transcoding needed). It has multi-server sign-in with DPAPI-encrypted tokens, Now Showing using the same rotation rules, a Movies and TV library, a theater window with curtains, a screen glow, seat rows, dimming house lights, a preshow and auto-hiding controls, and watch parties that sync with the iPhone app.
- CI publishes the IPA and the Windows builds to a GitHub prerelease (`v0.2.0-preview`).

### Changed
- Saved settings are merged with new defaults, so upgrades never reset your configuration.
- The rotation orders the catalog by Jellyfin item id, so iPhone and Windows pick the same Now Showing films from the same server.

## 0.1.0: Native Cinema Foundation (2026-10-24)

### Added
- Native iOS Xcode project in Swift, SwiftUI and Metal. There are no third-party engines or dependencies.
- **ZMF Cinema Engine**: a custom Metal forward renderer with PBR-style lighting, a live screen area light, dimmable house lights, fog, ACES tone mapping, zone culling, static batching, quality profiles and thermal fallback.
- Explorable 3D building: a lobby with box office, concessions and kiosks, an auditorium hall, and **twelve themed auditoriums**. Each auditorium has stadium seating (64 recliners), row and seat signage, a screen, curtains, sconces, step lights and decoration specific to its theme.
- Touch controls: virtual joystick, swipe-to-look, Interact / Sit / Stand / Recline, a first- and third-person camera, a map, and adjustable control size and sensitivity.
- **Multi-server Jellyfin integration**: authentication, Keychain storage of credentials and tokens, library discovery and selection, paged catalog sync, a unified deduplicated catalog with preferred sources, and an offline catalog cache.
- **Real playback**: PlaybackInfo negotiation with an iOS device profile (Direct Play or HLS remux/transcode), AVPlayer frames rendered onto the in-world screen, Jellyfin session reporting, local and server resume, audio track and WebVTT subtitle selection, retry on failure, and immersive fullscreen mode.
- Ticketing with a seat map, VIP rows, refunds, door access control, and navigation guidance to your seat.
- Automatic preshow: welcome card, imported trailers, reminder card, animated ZMF ident and countdown, with lights dimming and the feature starting automatically.
- **72-hour rotation director**: wall-clock periods, a seeded selection with repeat cooldown, a fallback hierarchy, the permanent 1900–1999 rule for Room 01, overrides and exclusions.
- Per-room showtimes in the owner's time zone, with preshow and feature times listed separately.
- Private screenings of any library movie or TV episode, and continuous episode playback with an intermission.
- **ZMF CASH** economy: a starting balance, Friday rewards, daily bonus, snacks you can carry and eat in your seat, purchase history, and an admin unlimited-cash mode.
- Admin Center: library, servers, rotation, showtimes, trailers and preshow, economy, graphics and controls, playback and watch history. Planned modules are clearly labelled.
- Unit tests and Jellyfin API fixture tests. CI builds an unsigned IPA, and a signed IPA when signing secrets are configured.
