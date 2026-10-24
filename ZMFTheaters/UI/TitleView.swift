import SwiftUI

struct TitleView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    @EnvironmentObject var wallet: Wallet
    @State private var showServers = false
    @State private var showAdmin = false
    @State private var glow = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.02, blue: 0.08), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 4) {
                        Text("ZMF")
                            .font(.system(size: 72, weight: .black))
                            .foregroundStyle(LinearGradient(colors: [.yellow, .orange], startPoint: .top, endPoint: .bottom))
                            .shadow(color: .orange.opacity(glow ? 0.9 : 0.3), radius: glow ? 24 : 8)
                        Text("THEATERS+").font(.system(size: 30, weight: .heavy)).foregroundStyle(.white)
                        Text("PRIVATE CINEMA UNIVERSE · v0.1").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    statusCard

                    HStack(spacing: 14) {
                        ModeCard(title: "Singleplayer", subtitle: "The whole cinema to yourself. Explore, buy a ticket, watch your films.",
                                 symbol: "person.fill", enabled: true) { model.mode = .singleplayer }
                        ModeCard(title: "Private AI Cinema", subtitle: "AI moviegoers & staff bring the building to life. Arrives in v0.3.",
                                 symbol: "person.3.fill", enabled: false) {}
                    }
                    .frame(maxWidth: 720)

                    HStack(spacing: 12) {
                        Button { showServers = true } label: { Label("Jellyfin Servers", systemImage: "server.rack") }
                        Button { showAdmin = true } label: { Label("Admin Center", systemImage: "slider.horizontal.3") }
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                .padding()
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever()) { glow = true } }
        .sheet(isPresented: $showServers) { NavigationStack { ServerManagerView() } }
        .sheet(isPresented: $showAdmin) { AdminView() }
    }

    private var statusCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading) {
                Text("\(library.servers.count) server\(library.servers.count == 1 ? "" : "s")").font(.headline)
                Text("\(library.movies.count) movies · \(library.series.count) shows").font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 30)
            VStack(alignment: .leading) {
                Text("Z$\(wallet.balance)").font(.headline).foregroundStyle(.yellow)
                Text("ZMF CASH (fictional)").font(.caption).foregroundStyle(.secondary)
            }
            if library.servers.isEmpty {
                Divider().frame(height: 30)
                Button("Connect Jellyfin") { showServers = true }.buttonStyle(.borderedProminent).tint(.orange)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title)
                Text(title).font(.title3.bold())
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Text(enabled ? "ENTER CINEMA" : "COMING IN v0.3").font(.caption.bold()).foregroundStyle(enabled ? .orange : .gray)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(enabled ? Color.orange.opacity(0.18) : Color.gray.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(enabled ? Color.orange : Color.gray.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
