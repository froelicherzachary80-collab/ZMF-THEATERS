import SwiftUI

enum BoxOfficeTab: String, CaseIterable, Identifiable {
    case nowShowing = "Now Showing"
    case movies = "Movies"
    case shows = "TV Shows"
    case tickets = "My Tickets"
    var id: String { rawValue }
}

struct BoxOfficeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State var startTab: BoxOfficeTab
    @State private var tab: BoxOfficeTab = .nowShowing
    @State private var search = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $tab) {
                    ForEach(BoxOfficeTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                switch tab {
                case .nowShowing: NowShowingList()
                case .movies: LibraryGrid(items: filtered(library.movies))
                case .shows: LibraryGrid(items: filtered(library.series))
                case .tickets: TicketsList()
                }
            }
            .navigationTitle("ZMF Box Office")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search your libraries")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Z$\(model.wallet.balance)").font(.headline).foregroundStyle(.yellow)
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .overlay {
                if library.servers.isEmpty && tab != .tickets {
                    ContentUnavailableView("No Jellyfin servers yet", systemImage: "server.rack",
                                           description: Text("Add a server in Admin Center → Server Manager. Your own movies appear here once synced."))
                }
            }
        }
        .onAppear { tab = startTab }
    }

    private func filtered(_ items: [MediaItem]) -> [MediaItem] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
}

// MARK: - Now Showing

struct NowShowingList: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    @EnvironmentObject var rotation: RotationDirector

    var body: some View {
        List {
            if let r = rotation.current {
                Section {
                    Text("Programme \(dateRange(r)) · new films every \(model.settings.rotationDays) days").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(CinemaRooms.all) { room in
                NowShowingRow(room: room, item: model.featured(room.id))
            }
        }
        .listStyle(.plain)
    }

    private func dateRange(_ r: Rotation) -> String {
        let f = DateFormatter()
        f.timeZone = model.settings.timeZone
        f.dateFormat = "MMM d"
        return "\(f.string(from: r.start))–\(f.string(from: r.end.addingTimeInterval(-1)))"
    }
}

struct NowShowingRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    let room: CinemaRoom
    let item: MediaItem?

    var body: some View {
        if let item {
            NavigationLink {
                TicketPurchaseView(item: item, room: room, featured: true)
            } label: {
                HStack(spacing: 12) {
                    PosterView(item: item, width: 60)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ROOM \(room.code) · \(room.name.uppercased())\(room.is3D ? " · 3D" : "")").font(.caption2.bold()).foregroundStyle(.orange)
                        Text(item.title).font(.headline)
                        Text(meta(item)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            ForEach(model.nextShowtimes(room.id, limit: 3)) { s in
                                Text(ShowtimeScheduler.timeFormatter(model.settings).string(from: s.featureStart))
                                    .font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2), in: Capsule())
                            }
                        }
                        if !library.isAvailable(item) {
                            Label("Server offline — playback unavailable until it reconnects", systemImage: "wifi.slash").font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
            }
        } else {
            HStack {
                Text("ROOM \(room.code) · \(room.name)").font(.subheadline.bold())
                Spacer()
                Text("No eligible film (\(room.eraLabel))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func meta(_ i: MediaItem) -> String {
        var parts: [String] = []
        if let y = i.year { parts.append(String(y)) }
        if let m = i.runtimeMinutes { parts.append("\(m) min") }
        if let r = i.videoResolution { parts.append(r) }
        parts.append(contentsOf: i.genres.prefix(2))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Complete library

struct LibraryGrid: View {
    let items: [MediaItem]
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    NavigationLink {
                        if item.kind == .series { SeriesView(series: item) } else { MovieDetailView(item: item) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            PosterView(item: item, width: 104)
                            Text(item.title).font(.caption.bold()).lineLimit(2).foregroundStyle(.primary)
                            Text(item.year.map(String.init) ?? "").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

struct MovieDetailView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    let item: MediaItem

    var body: some View {
        let room = CinemaRooms.bestRoom(for: item)
        let sources = library.sources(for: item)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    PosterView(item: item, width: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title2.bold())
                        Text([item.year.map(String.init), item.runtimeMinutes.map { "\($0) min" }, item.officialRating, item.videoResolution]
                            .compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                        Text(item.genres.joined(separator: ", ")).font(.caption)
                        if !item.audioLanguages.isEmpty { Text("Audio: \(item.audioLanguages.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary) }
                        if !item.subtitleLanguages.isEmpty { Text("Subtitles: \(item.subtitleLanguages.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary) }
                        Text("Source: \(library.server(for: item)?.displayName ?? "?")\(library.isAvailable(item) ? "" : " (offline)")").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let o = item.overview { Text(o).font(.callout) }
                if sources.count > 1 {
                    VStack(alignment: .leading) {
                        Text("Also on \(sources.count - 1) other server(s) — preferred playback source:").font(.caption.bold())
                        ForEach(sources) { s in
                            Button {
                                library.setPreferredSource(s)
                            } label: {
                                Label("\(library.server(for: s)?.displayName ?? "?") · \(s.videoResolution ?? "?")",
                                      systemImage: library.preferredSources[s.dedupeKey] == s.id ? "checkmark.circle.fill" : "circle")
                            }
                        }
                    }
                }
                NavigationLink {
                    TicketPurchaseView(item: item, room: room, featured: false)
                } label: {
                    Label("Private screening in Room \(room.code) · \(room.name)", systemImage: "ticket.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding()
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SeriesView: View {
    @EnvironmentObject var library: MediaLibrary
    let series: MediaItem
    @State private var seasons: [JFItem] = []
    @State private var seasonId: String?
    @State private var episodes: [MediaItem] = []
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if !seasons.isEmpty {
                Picker("Season", selection: $seasonId) {
                    ForEach(seasons, id: \.id) { s in Text(s.name ?? "Season").tag(Optional(s.id)) }
                }
            }
            ForEach(Array(episodes.enumerated()), id: \.element.id) { idx, ep in
                NavigationLink {
                    TicketPurchaseView(item: ep, room: CinemaRooms.bestRoom(for: ep, seriesGenresFrom: series), featured: false,
                                       episodeQueue: episodes.suffix(from: idx + 1).map { $0.id })
                } label: {
                    VStack(alignment: .leading) {
                        Text("E\(ep.indexNumber ?? idx + 1) · \(ep.title)").font(.subheadline.bold())
                        if let o = ep.overview { Text(o).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
            }
        }
        .navigationTitle(series.title)
        .task {
            do {
                seasons = try await library.seasons(of: series)
                seasonId = seasons.first?.id
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: seasonId) { _, id in
            guard let id else { return }
            Task {
                do {
                    let eps = try await library.episodes(of: series, seasonId: id)
                    library.remember(eps)
                    episodes = eps
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - Tickets

struct TicketsList: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wallet: Wallet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            let active = wallet.activeTickets
            if active.isEmpty {
                Text("No active tickets. Buy one from Now Showing or your library.").foregroundStyle(.secondary)
            }
            ForEach(active) { t in
                VStack(alignment: .leading, spacing: 4) {
                    Text(t.title).font(.headline)
                    Text("Room \(String(format: "%02d", t.roomId)) · \(CinemaRooms.room(t.roomId).name) · Seat \(t.seatLabel) · \(t.kind.label)")
                        .font(.caption)
                    Text(t.showtime.map { "Showing \(ShowtimeScheduler.timeFormatter(model.settings).string(from: $0))" } ?? "Private screening — starts when you sit")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button("Guide me there") { model.guide(to: t); dismiss() }.buttonStyle(.borderedProminent).tint(.orange)
                        Button("Refund Z$\(t.price)", role: .destructive) { model.refund(t) }.buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
            let past = wallet.tickets.filter { $0.status != .active }.prefix(20)
            if !past.isEmpty {
                Section("History") {
                    ForEach(Array(past)) { t in
                        HStack {
                            Text(t.title).font(.caption)
                            Spacer()
                            Text(t.status == .used ? "Watched" : "Refunded").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
