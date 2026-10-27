# Building ZMF THEATERS+

## Requirements

- macOS with **Xcode 16 or newer**. The project uses synchronized folder groups (`objectVersion 77`). Xcode 26 is recommended for the iOS 26 SDK.
- An iPhone running iOS 18 or later. The target device is the iPhone 16 Pro on iOS 26. The deployment target is 18.0 so the project builds with every current Xcode.
- No package dependencies. Everything uses Apple frameworks: SwiftUI, Metal, MetalKit, AVFoundation, CoreVideo and Security.

## Xcode

```bash
git clone https://github.com/froelicherzachary80-collab/ZMF-THEATERS.git
cd ZMF-THEATERS
open ZMFTheaters.xcodeproj
```

1. Select the **ZMFTheaters** target → **Signing & Capabilities** → choose your Team. Change the bundle ID (`com.zmf.theatersplus`) if Xcode asks for a unique one.
2. Pick your iPhone as the run destination and press **⌘R**.
3. Press **⌘U** to run the tests on a simulator.

## Command line

```bash
# Tests
xcodebuild test -project ZMFTheaters.xcodeproj -scheme ZMFTheaters \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO

# Unsigned device build → IPA (re-sign before installing)
xcodebuild build -project ZMFTheaters.xcodeproj -scheme ZMFTheaters -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/ZMFTheaters.app Payload/
zip -qry ZMFTheaters-unsigned.ipa Payload

# Signed archive + export
xcodebuild archive -project ZMFTheaters.xcodeproj -scheme ZMFTheaters -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/ZMFTheaters.xcarchive DEVELOPMENT_TEAM=YOURTEAMID
xcodebuild -exportArchive -archivePath build/ZMFTheaters.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
```

Edit `ExportOptions.plist` first: set `teamID` and the profile name, or change `method` to `debugging` for a development build.

## Architecture notes

- **Rendering.** `Renderer` draws on a `CAMetalLayer` that is driven by a `CADisplayLink`. Static geometry from `WorldGeometry` is batched per material inside each zone: the lobby and hall form one zone, and each auditorium is its own zone. Only visible zones are drawn.
- **Video on the screen.** `PlaybackEngine` attaches an `AVPlayerItemVideoOutput` (BGRA, Metal-compatible). Each frame, the renderer copies the newest pixel buffer and wraps it as an sRGB texture through `CVMetalTextureCache`, with no CPU copy. A one-threadgroup compute kernel averages the frame so the shader can light the room with the screen's colour. Only the room hosting the current screening decodes video. Every other screen shows static preview signage.
- **Jellyfin.** `JellyfinClient` handles one server. `MediaLibrary` owns one client per `ServerAccount`, merges catalogs, retries after an HTTP 401 by logging in again with the Keychain password, and persists the catalog.
- **Rotation.** `RotationDirector.select` is a pure, seeded function covered by unit tests. Its six-level fallback hierarchy is documented in the code and in the Admin Center.


## v0.5.2 — YouTube auditorium screen lock

The official YouTube WKWebView is **not** composited into Metal or downloaded: it is a native interactive view positioned with the **same Metal camera projection and auditorium screen geometry** as the 3D room. The player rectangle is recalculated from the fixed world-space CinemaWorld screen and camera each animation frame; the virtual 4DX chair changes only the viewer camera. Do not apply FourDXMotionStage rotation/offset/scale to the player. When the chair banks, rises or vibrates, the auditorium and the video screen remain joined in world space. Video controls stay interactive and movie playback is not restarted when the projected rectangle moves. The real auditorium screen underneath is blacked out while YouTube occupies it; HUD controls remain separate from screen content. Preshow trailers follow the same rule.

This is a perspective-aligned **2D WKWebView** over a gently curved 3D mesh, not GPU video-texture extraction or perfect perspective warping. The YouTube 3D choice remains a stereo-window effect, not per-pixel depth estimation. Embedded video restrictions still apply. CI includes projection, mirrored-room, camera movement and behind-camera tests; iOS simulator media playback requires network and video embed permissions.
