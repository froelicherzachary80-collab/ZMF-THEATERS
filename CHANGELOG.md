# Changelog

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
