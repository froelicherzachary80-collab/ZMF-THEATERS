# Watch parties: watching with a friend online

ZMF THEATERS+ watch parties use **Jellyfin SyncPlay**, which is built into Jellyfin 10.7 and newer. **Your own Jellyfin server is the "public server."** Everyone streams the film from it, and SyncPlay tells every device exactly when to play, pause and seek. You don't need a VPS or a paid service.

Who can join:

- ZMF THEATERS+ on iPhone. Friends appear seated beside you with name tags.
- ZMF THEATERS+ for Windows (`ZMFTheaters.exe`).
- Any official Jellyfin client with SyncPlay, such as Jellyfin Web or Jellyfin Media Player.

## One-time setup (server owner)

1. **Create an account for your friend.** In Jellyfin, go to Dashboard → Users → **+**. Give the account access to the libraries you want to share. Under **SyncPlay access**, choose *Allow joining and creating groups*.
2. **Make your server reachable from the internet over HTTPS.** Pick one:
   - **Tailscale (easiest, free, private):** install Tailscale on the server, then share the machine with your friend's Tailscale account. Your friend uses the server's Tailscale address, for example `http://100.x.y.z:8096`, or the HTTPS MagicDNS name if you enabled HTTPS in Tailscale.
   - **Cloudflare Tunnel:** this needs a domain you own. It publishes `https://jellyfin.yourdomain.com` without opening router ports.
   - **Reverse proxy:** Caddy or Nginx with a Let's Encrypt certificate, plus router port-forwarding of 443.
3. **Send your friend the server address and their username and password.**

## Hosting

- **iPhone:** start a screening and sit down. Then either tap the **PARTY** button in the top bar or the 👥 button in the playback controls, and choose **Start a watch party**.
- **Windows:** open a film and click **Host watch party**.

## Joining

- **iPhone:** Title screen → **Jellyfin Servers** → add the host's server with your account. Then go to **Watch Parties** → **Join**. You are seated in the right auditorium automatically.
- **Windows:** **Servers** tab → add the host's server. Then **Watch Parties** → **Join**.

## How sync works

- Play, pause and seek from **anyone** go to the server, and the server tells everyone when to act.
- Each app estimates the server clock using `/GetUtcTime`. It corrects small drift (0.15–1.5 s) by speeding up or slowing down playback slightly. For bigger gaps it re-seeks.
- If someone is buffering, SyncPlay waits for them before resuming.

## Limits

- Everyone must use accounts **on the same Jellyfin server**, because SyncPlay groups belong to one server.
- Your upload speed limits how many friends can stream at once. A 1080p film at original quality may need 10–40 Mbps per viewer.
- Voice and text chat are not built in yet. Use a call app alongside.
