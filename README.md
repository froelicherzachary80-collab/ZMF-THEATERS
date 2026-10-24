# ZMF THEATERS+

**AAA-inspired private cinema universe for iPhone, with a Windows 10/11 companion app. Version 0.2.**

**Downloads:** the latest builds are attached to the [`v0.2.0-preview` release](../../releases/tag/v0.2.0-preview):

- `ZMFTheaters-unsigned.ipa` for iPhone (see [docs/INSTALL.md](docs/INSTALL.md))
- `ZMFTheaters.exe` for Windows 10/11 (single file; Windows SmartScreen may warn because the exe isn't code-signed: choose *More info → Run anyway*)
- `ZMFTheaters-Windows-x64.zip`, the same Windows app as a portable folder

**New in 0.2:** the controls hide while you watch, the renderer has HDR bloom, a projector beam with dust and a curved screen, and you can host **online watch parties with friends** through Jellyfin SyncPlay ([guide](docs/WATCH_PARTY.md)).

ZMF THEATERS+ is a single-player 3D movie theater for iPhone. You walk into a cinema building, buy a ticket with fictional ZMF CASH, walk to the right auditorium, sit in your seat, and watch real movies and TV episodes streamed from **your own Jellyfin servers** on the giant in-world screen.

The app has no multiplayer, no other human players, no real-money purchases, and no Streambert.

> Swift + SwiftUI + a custom Metal renderer + AVFoundation. No Unity, Unreal, Godot, web views or paid APIs.

---

## What works in v0.1

The main flow is **connect Jellyfin → choose a movie → buy a ticket → enter the auditorium → sit down → watch the real movie.**

| Area | Status in v0.1 |
|---|---|
| **Jellyfin, multiple servers** | Add, edit, remove, test and sync any number of servers. Password login uses `/Users/AuthenticateByName`. Library selection, connection status and last sync time are shown. Passwords and tokens are kept in the **Keychain**. Each server has its own client, so a token is never sent to a different server. After an HTTP 401 the app logs in again automatically. Nothing on the server is ever changed. |
| **Unified catalog** | Movies and series from every server are merged into one catalog. Each title shows poster, backdrop, year, runtime, genres, overview, resolution, audio and subtitle languages, source server and availability. Duplicates are detected by TMDb or IMDb id, or by title + year, and you pick the preferred source. The catalog is saved, so it is still browsable while a server is offline. |
| **Playback** | `/Items/{id}/PlaybackInfo` is called with an iOS device profile. The app uses **Direct Play** for MP4/MOV files with H.264/HEVC. Anything else is remuxed or transcoded by Jellyfin into **HLS**. Playback runs on AVPlayer. Frames are pulled with `AVPlayerItemVideoOutput`, mapped into Metal through `CVMetalTextureCache` and **drawn on the virtual screen** at the correct aspect ratio. Start, progress and stop are reported to Jellyfin through `/Sessions/Playing*`. Resume uses both the server position and a local one. Audio track switching, text subtitles (fetched as WebVTT), volume, buffering status, sleep prevention, real error messages and Retry are included. |
| **3D world** | A lobby with box office, concessions (popcorn, soda, slushie and candy machines), ticket kiosks and a marquee. An auditorium hall with 12 lit doorways. **Twelve complete auditoriums** with real walls, ceilings, stadium risers and stage, a screen with masking curtains, 64 reclining seats each (VIP rows E–F), seat number plaques, row letters, wall sconces, LED step lights, exit signs and themed decoration. |
| **Renderer** | A custom Metal forward renderer. It uses PBR-style shading (Lambert + GGX + Schlick), selects the 16 most relevant point lights each frame, and adds a **screen area light whose colour is the live average of the movie frame**, so the screen lights the room. It also has dimmable house lights, exponential fog, ACES tone mapping, static batching per zone, zone culling (only rooms you can see are drawn), quality profiles, and automatic 30 FPS / lower resolution when the phone is hot or in Low Power Mode. |
| **Controls** | Left joystick to walk, swipe on the right to look, and Interact / Sit / Stand / Recline buttons. The top bar has Map, Ticket, Wallet, Phone, Camera (1st/3rd person), Admin and Exit. Joystick size and look sensitivity are adjustable, and the controls can swap sides. Landscape is the main orientation, with safe areas respected. |
| **Seating** | A seat map for each showing. Tickets show room and seat. A navigation arrow guides you, auditorium doors only open with a valid ticket, and a pulsing marker sits over your seat. Sitting blends into a seated camera, and you can recline and look around while the film plays. Optional fullscreen mode uses the same AVPlayer, so the playback position is kept. |
| **Preshow** | Welcome card, then trailers **you import** (Files → Trailers, or the Admin importer), then a reminder card, an animated ZMF ident and a countdown. The house lights dim, the feature starts automatically, and the lights come back up after the credits. All durations are editable, and you can skip the preshow. |
| **72-hour rotation** | Twelve featured films, one per room, every 3 days. Periods are counted from a fixed anchor using the wall clock, so the right rotation is restored after the app has been closed. The selection is deterministic and seeded, honours a repeat cooldown, and uses a documented fallback hierarchy. **Room 01 never relaxes its 1900–1999 rule.** The admin can set excluded movies or libraries, preferred genres, per-room overrides, and force a new rotation. |
| **Complete library** | Any movie or episode can get a private screening right away. The best room is chosen from genre and era, and the admin can override it. TV is browsed by series, season and episode. Continuous episode playback has a configurable intermission. |
| **Showtimes** | Each room has its own daily schedule in your time zone (default America/New_York). Preshow and feature start times are listed separately, and cleanup time is included. You never "miss" a film: the screening starts when you sit down. |
| **ZMF CASH** | Z$5,000 to start, Z$3,000 every Friday, and a daily attendance bonus. Tickets are Z$150, Z$225 for 3D and Z$350 for VIP. Snacks can be bought, carried and eaten in your seat. Refunds, purchase history, and an unlimited-cash test mode are included. It is fictional money only. |
| **Admin Center** | Movie Library, Server Manager, Rotation Director, Showtime Manager, Trailer & Preshow Manager, Economy, Graphics & Controls, Playback / watch history, and a door override. |

### Not in v0.1 yet

These features are on the roadmap. Where the UI mentions them, it labels them as planned rather than faking them.

- **Private AI Cinema mode** (NPC moviegoers and staff): v0.3. The mode card is shown but disabled.
- **ZMF DepthCinema AI red/cyan 3D**: v0.5. Rooms 07–12 currently play **genuine 2D**. No colour filter is applied to pretend it is 3D.
- **Spatial cinema audio**: v0.4. Audio currently plays through the normal iOS output.
- **Themed event weeks** (Marvel, Halloween Oct 25–31, Romance, Christmas, Summer, Classic Hollywood, custom): v0.6.
- **Room Designer** and dynamic shadows, bloom and reflections: v0.4.
- **Image-based subtitles** (PGS/VobSub burn-in): later. Text subtitles work now.
- **Emby, Plex and WebDAV providers**: after Jellyfin is complete.
- Persistence is Codable JSON in Application Support. Migrating to SwiftData is planned.
- Character art and environments are procedural blockout geometry with real lighting. They are not hand-modelled AAA assets yet.

---

## Getting the IPA

Every push runs [`.github/workflows/ios.yml`](.github/workflows/ios.yml) on a GitHub macOS runner. It does three things:

1. Runs the unit and API-fixture tests on an iPhone simulator.
2. Builds the Release app for devices and packages **`ZMFTheaters-unsigned.ipa`**.
3. If signing secrets are configured, archives and exports a **signed `ZMFTheaters.ipa`**.

To download the IPA: GitHub → **Actions** → latest run → **Artifacts → ZMFTheaters-ipa**.

See [docs/INSTALL.md](docs/INSTALL.md) for installing it on your iPhone, and [docs/BUILD.md](docs/BUILD.md) for building locally in Xcode.

## Windows app

`windows/ZMFTheaters.Windows` is a native WPF (.NET 8) app. It is **not** the 3D world (that is iPhone-only for now). It is a cinema-styled companion app:

- **Now Showing:** the same 72-hour rotation rules as the iPhone app.
- **Library:** your movies and TV, across all your servers.
- **Theater window:** red curtains, a glowing screen, rows of seats, house lights that dim for the feature, a preshow and countdown, and auto-hiding controls. You get audio and subtitle track selection, keyboard shortcuts (Space, ←/→, F, Esc) and a fullscreen-picture mode.
- **Playback:** uses **LibVLC**, so MKV, HEVC, DTS and other formats stream untouched from Jellyfin, with no server transcoding.
- **Watch Parties:** host or join SyncPlay groups. These stay in sync with friends on iPhone or any Jellyfin app.

Build it locally with `dotnet publish windows/ZMFTheaters.Windows -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeAllContentForSelfExtract=true`.

## Project layout

```
ZMFTheaters.xcodeproj        Xcode 16+ project (synchronized folders)
ZMFTheaters/
  App/        App entry point and AppModel wiring
  Core/       Models, Keychain, JSON persistence, settings, ZMF CASH wallet
  Media/      Jellyfin DTOs + API client, multi-server library, image loader, playback engine
  Cinema/     12 rooms, rotation director, showtimes, screening/preshow session
  Engine/     Metal renderer, shaders, world layout & geometry, game controller, textures
  UI/         SwiftUI HUD, box office, ticketing & seat map, server manager, admin center
ZMFTheatersTests/              Jellyfin API fixture tests, rotation/showtime/world tests
Support/Info.plist             ATS / local network / background audio keys
ExportOptions.plist            Example signed-export options
```

## Acceptance test (with your real server)

1. Admin Center → Server Manager → **Add Server**. Enter your HTTPS URL, username and password, then tap **Test & Connect**, choose libraries, and tap **Save & sync**.
2. Box Office → **Now Showing** should list twelve of your real movies with real posters.
3. Pick one, choose a seat and **Buy ticket**. Your Z$ balance should drop.
4. Follow the arrow to the hall. The room's door light turns green and the doors slide open.
5. Walk to the glowing marker and tap **SIT**.
6. The preshow plays and the lights dim. Your movie then streams from Jellyfin onto the screen with synchronized audio, and the room glows with the picture.
7. Stand up, leave, and come back: the app offers **Resume**.

If the stream can't start, the screen shows the actual error and a **Retry** button.

## Licence & content

All code and art in this repository are original. Only stream media you own or are licensed to use. Import AMC or any other third-party preshow material only if you have permission. Nothing is downloaded or copied automatically.
