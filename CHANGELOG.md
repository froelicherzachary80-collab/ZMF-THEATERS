# Changelog

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
