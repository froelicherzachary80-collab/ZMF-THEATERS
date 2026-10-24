import SwiftUI

struct WatchPartyView: View {
    @EnvironmentObject var party: WatchParty
    @EnvironmentObject var session: TheaterSession
    @EnvironmentObject var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle().fill(party.isInParty ? Color.green : Color.gray).frame(width: 10, height: 10)
                        Text(party.status).font(.subheadline.bold())
                        if party.busy { Spacer(); ProgressView() }
                    }
                }

                if let g = party.group {
                    Section("In this party") {
                        Text(g.name).font(.headline)
                        ForEach(party.members, id: \.self) { m in
                            Label(m == party.myName ? "\(m) (you)" : m, systemImage: "person.fill")
                        }
                        Button("Leave party", role: .destructive) { Task { await party.leave() } }
                    }
                    if !party.events.isEmpty {
                        Section("Activity") {
                            ForEach(Array(party.events.prefix(12).enumerated()), id: \.offset) { _, e in Text(e).font(.caption) }
                        }
                    }
                } else {
                    Section("Host") {
                        if let item = session.item, session.feature.isActive {
                            Button {
                                Task { await party.host(item: item) }
                            } label: {
                                Label("Start a watch party for “\(item.displayTitle)”", systemImage: "person.2.wave.2.fill")
                            }
                        } else {
                            Text("Sit down and start a screening first, then host a party for it.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        if party.groups.isEmpty {
                            Text("No parties right now.").foregroundStyle(.secondary)
                        }
                        ForEach(party.groups) { g in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(g.name).font(.subheadline.bold())
                                    Text("\(g.participants.joined(separator: ", ")) · \(g.state) · \(library.servers.first { $0.id == g.serverId }?.displayName ?? "")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Join") { Task { await party.join(g); dismiss() } }.buttonStyle(.borderedProminent).tint(.orange)
                            }
                        }
                        Button { Task { await party.refreshGroups() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    } header: {
                        Text("Parties on your servers")
                    }
                }

                Section("How a friend joins") {
                    Text("""
                    1. In your Jellyfin dashboard create a user for your friend, give it access to your movie libraries and allow SyncPlay ("Create and join groups").
                    2. Make your server reachable from the internet over HTTPS — e.g. invite them to your Tailscale network, or use a Cloudflare Tunnel / reverse proxy.
                    3. Your friend signs in to that server from ZMF THEATERS+ (iPhone), ZMF THEATERS+ for Windows, or any official Jellyfin app, opens Watch Parties and taps Join.
                    Everyone streams from your server and SyncPlay keeps play, pause and seek in lock-step.
                    """)
                    .font(.caption)
                }
            }
            .navigationTitle("Watch Party")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await party.refreshGroups() }
        }
    }
}
