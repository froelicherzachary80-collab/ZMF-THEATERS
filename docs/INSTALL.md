# Installing ZMF THEATERS+ on your iPhone

Every iOS app must be code-signed before it will run on a device. The CI workflow produces two kinds of IPA, and each one needs a different setup.

## Option A: unsigned IPA plus a sideloading tool (free Apple ID)

1. Open the repository on GitHub, go to **Actions**, open the latest successful **iOS build & IPA** run, and download the **ZMFTheaters-ipa** artifact. Unzip it to get `ZMFTheaters-unsigned.ipa`.
2. Install a sideloading tool on your computer:
   - **Sideloadly** (Windows/macOS): drag the IPA in, sign in with your Apple ID, and click Start.
   - **AltStore** (Windows/macOS + AltServer): use My Apps → **+** → choose the IPA.
3. On the iPhone, go to **Settings → Privacy & Security → Developer Mode** and turn it on (this is required on iOS 16 and later), then reboot.
4. Go to **Settings → General → VPN & Device Management** and trust your Apple ID's developer profile.
5. Launch **ZMF THEATERS+**.

With a free Apple ID, sideloaded apps expire after **7 days**. Re-sign the app in Sideloadly or AltStore to refresh it. Your data (servers, wallet, rotation) is kept if you re-sign with the same bundle ID.

## Option B: signed IPA from CI (paid Apple Developer account)

Add these **repository secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `base64 -i AppleDevelopment.p12` (your signing certificate and private key) |
| `P12_PASSWORD` | Password of that .p12 |
| `PROVISIONING_PROFILE_BASE64` | `base64 -i ZMFTheaters.mobileprovision` (Ad Hoc or Development profile for `com.zmf.theatersplus` that includes your iPhone's UDID) |
| `TEAM_ID` | Your 10-character Apple team ID |

The next run then also uploads `signed/ZMFTheaters.ipa`. You can install it with Apple Configurator, Xcode (**Window → Devices and Simulators → +**), or any Ad Hoc distribution tool.

## Option C: build from Xcode on a Mac

See [BUILD.md](BUILD.md). Plug in the iPhone, choose your team under Signing & Capabilities, and press Run.

## First launch

1. Tap **Jellyfin Servers** → **Add Server**.
2. Use an HTTPS address that your iPhone can reach, for example a reverse proxy or a private VPN such as Tailscale. Plain `http://` works on your LAN, but the app will warn you.
3. When iOS asks for **Local Network** access, allow it.
4. Sync your libraries, then tap **Singleplayer** to enter the cinema.
