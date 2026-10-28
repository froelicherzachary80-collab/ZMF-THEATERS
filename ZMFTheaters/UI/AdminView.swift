import SwiftUI
import UniformTypeIdentifiers

/// Owner-only Admin Center. Sections not yet built in v0.1 say so plainly.
struct AdminView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Media") {
                    NavigationLink { AdminLibraryView() } label: { Label("Movie Library", systemImage: "film.stack") }
                    NavigationLink { ServerManagerView() } label: { Label("Server Manager", systemImage: "server.rack") }
                }
                Section("Programming") {
                    NavigationLink { RotationAdminView() } label: { Label("Rotation Director", systemImage: "calendar.badge.clock") }
                    NavigationLink { ShowtimeAdminView() } label: { Label("Showtime Manager", systemImage: "clock") }
                    NavigationLink { PreshowAdminView() } label: { Label("Trailer & Preshow Manager", systemImage: "play.rectangle.on.rectangle") }
                    NavigationLink { PlannedView(title: "Event Creator", version: "v0.6", detail: "Marvel Week, Halloween Week (Oct 25–31), Romance, Christmas, Summer Blockbuster, Classic Hollywood and custom events with lighting, decorations and rotation overrides.") } label: { Label("Event Creator", systemImage: "sparkles") }
                }
                Section("Cinema") {
                    NavigationLink { EconomyAdminView() } label: { Label("Economy Manager", systemImage: "creditcard") }
                    NavigationLink { GraphicsAdminView() } label: { Label("Graphics & Controls", systemImage: "paintbrush") }
                    NavigationLink { PlaybackAdminView() } label: { Label("Playback", systemImage: "play.circle") }
                    NavigationLink { StereoAdminView() } label: { Label("3D Cinema Settings", systemImage: "eyeglasses") }
                    NavigationLink { FourDXAdminView() } label: { Label("Immersive 4DX", systemImage: "wind") }
                    NavigationLink { GoveeIOSView() } label: { Label("iPhone Govee Lighting", systemImage: "lightbulb.led.wide") }
                    NavigationLink { PlannedView(title: "AI Control", version: "v0.3", detail: "Procedural AI moviegoers and employees with names, outfits, personalities and daily schedules — no paid LLM required.") } label: { Label("AI Control", systemImage: "person.3") }
                    NavigationLink { PlannedView(title: "Room Designer", version: "v0.4", detail: "Per-room lighting colour, decoration density and ambience. Genre identity and Room 01's 1900–1999 rule stay fixed.") } label: { Label("Room Designer", systemImage: "paintpalette") }
                }
                Section("Access") {
                    Toggle("Unlock all auditorium doors", isOn: Binding(get: { model.settingsStore.settings.allDoorsUnlocked },
                                                                         set: { model.settingsStore.settings.allDoorsUnlocked = $0 }))
                }
            }
            .navigationTitle("Admin Center")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct PlannedView: View {
    let title: String
    let version: String
    let detail: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "hammer")
        } description: {
            Text("Planned for \(version) on the roadmap.\n\n\(detail)")
        }
    }
}

struct AdminLibraryView: View {
    @EnvironmentObject var library: MediaLibrary
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var search = ""

    var body: some View {
        let movies = library.movies.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        List(movies) { m in
            let excluded = settingsStore.settings.excludedMediaIds.contains(m.id)
            HStack {
                VStack(alignment: .leading) {
                    Text(m.title).font(.subheadline.bold())
                    Text("\(m.year.map(String.init) ?? "?") · \(m.genres.prefix(3).joined(separator: ", ")) · \(library.server(for: m)?.displayName ?? "?") · Room \(CinemaRooms.bestRoom(for: m).code)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(excluded ? "Excluded" : "In rotation") {
                    if excluded { settingsStore.settings.excludedMediaIds.removeAll { $0 == m.id } }
                    else { settingsStore.settings.excludedMediaIds.append(m.id) }
                }
                .font(.caption).buttonStyle(.bordered).tint(excluded ? .red : .green)
            }
        }
        .searchable(text: $search)
        .navigationTitle("Movie Library (\(library.movies.count))")
    }
}

struct RotationAdminView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var rotation: RotationDirector
    @EnvironmentObject var library: MediaLibrary
    @State private var genres = ""

    var body: some View {
        Form {
            Section("Rules") {
                Toggle("Automatic rotation", isOn: $settingsStore.settings.rotationEnabled)
                Stepper("Every \(settingsStore.settings.rotationDays) day(s)", value: $settingsStore.settings.rotationDays, in: 1...14)
                Stepper("Repeat cooldown: \(settingsStore.settings.repeatCooldownRotations) rotations", value: $settingsStore.settings.repeatCooldownRotations, in: 1...20)
                DatePicker("Rotation anchor", selection: $settingsStore.settings.rotationAnchor)
                TextField("Random seed", text: Binding(
                    get: { String(settingsStore.settings.rotationSeed) },
                    set: { if let v = UInt64($0) { settingsStore.settings.rotationSeed = v } }))
                    .keyboardType(.numberPad)
                TextField("Preferred genres (comma separated)", text: $genres)
                    .onSubmit { settingsStore.settings.preferredGenres = genres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                Text("Excluded movies: \(settingsStore.settings.excludedMediaIds.count) (manage in Movie Library)").font(.caption)
            }
            if let lib = library.servers.first, !lib.knownLibraries.isEmpty {
                Section("Excluded libraries") {
                    ForEach(library.servers) { s in
                        ForEach(s.knownLibraries) { l in
                            Toggle("\(s.displayName) · \(l.name)", isOn: Binding(
                                get: { settingsStore.settings.excludedLibraryIds.contains(l.id) },
                                set: { on in
                                    if on { settingsStore.settings.excludedLibraryIds.append(l.id) }
                                    else { settingsStore.settings.excludedLibraryIds.removeAll { $0 == l.id } }
                                }))
                        }
                    }
                }
            }
            Section {
                Button("Generate a new rotation now") { model.refreshProgramme(force: true) }
            }
            if let r = rotation.current {
                Section("Current rotation #\(r.index) · \(r.start.formatted(date: .abbreviated, time: .shortened)) → \(r.end.formatted(date: .abbreviated, time: .shortened))") {
                    ForEach(CinemaRooms.all) { room in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(room.code) \(room.name)").font(.caption.bold())
                            Text(model.featured(room.id)?.title ?? "—").font(.subheadline)
                            Text(r.notes[String(room.id)] ?? "").font(.caption2).foregroundStyle(.secondary)
                            OverridePicker(roomId: room.id)
                        }
                    }
                }
            }
            Section("Fallback hierarchy") {
                Text("1 genre match outside cooldown → 2 genre match not in previous rotation → 3 related genre → 4 any genre in era → 5 allow repeat → 6 share with another room. Room 01 is always 1900–1999.")
                    .font(.caption)
            }
        }
        .navigationTitle("Rotation Director")
        .onAppear { genres = settingsStore.settings.preferredGenres.joined(separator: ", ") }
        .onDisappear { model.refreshProgramme() }
    }
}

private struct OverridePicker: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var library: MediaLibrary
    let roomId: Int

    var body: some View {
        let room = CinemaRooms.room(roomId)
        let eligible = library.movies.filter { room.eraAllows($0) }
        Picker("Featured override", selection: Binding(
            get: { settingsStore.settings.featuredOverrides[String(roomId)] ?? "" },
            set: { v in settingsStore.settings.featuredOverrides[String(roomId)] = v.isEmpty ? nil : v })) {
            Text("Automatic").tag("")
            ForEach(eligible) { m in Text(m.title).tag(m.id) }
        }
        .font(.caption)
    }
}

struct ShowtimeAdminView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Schedule") {
                TextField("Time zone (IANA)", text: $settingsStore.settings.timeZoneId).textInputAutocapitalization(.never)
                Stepper("Opens \(settingsStore.settings.openingHour):00", value: $settingsStore.settings.openingHour, in: 0...23)
                Stepper("Last preshow before \(settingsStore.settings.closingHour % 24):00", value: $settingsStore.settings.closingHour, in: 12...30)
                Stepper("Cleanup between shows: \(settingsStore.settings.cleanupMinutes) min", value: $settingsStore.settings.cleanupMinutes, in: 0...60, step: 5)
            }
            Section("Today") {
                let f = ShowtimeScheduler.timeFormatter(settingsStore.settings)
                ForEach(CinemaRooms.all) { room in
                    let shows = ShowtimeScheduler.showtimes(roomId: room.id, runtimeMinutes: model.featured(room.id)?.runtimeMinutes, day: Date(), settings: settingsStore.settings)
                    VStack(alignment: .leading) {
                        Text("\(room.code) \(room.name)").font(.caption.bold())
                        Text(shows.map { f.string(from: $0.featureStart) }.joined(separator: "  ")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Showtime Manager")
        .onDisappear { model.refreshSignage() }
    }
}

struct PreshowAdminView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var importing = false
    @State private var files: [URL] = []
    @State private var youtubeLink = ""
    @State private var youtubeTitle = ""
    @State private var youtubeFormat: TrailerPresentation = .standard
    @State private var linkError: String?

    var body: some View {
        Form {
            Section("Sequence") {
                Toggle("Preshow before every screening", isOn: $settingsStore.settings.preshowEnabled)
                Toggle("Standard trailers", isOn: $settingsStore.settings.standardTrailersEnabled)
                Toggle("4DX / 4DX + 3D presentations (virtual motion)", isOn: $settingsStore.settings.fourDXTrailersEnabled)
                Stepper("Welcome: \(settingsStore.settings.welcomeSeconds)s", value: $settingsStore.settings.welcomeSeconds, in: 3...120)
                Stepper("Trailers: up to \(settingsStore.settings.maxTrailers)", value: $settingsStore.settings.maxTrailers, in: 0...6)
                Toggle("ZMF roller-coaster intro", isOn: $settingsStore.settings.coasterIntro)
                Toggle("Announcer voice", isOn: $settingsStore.settings.coasterVoice)
                    .disabled(!settingsStore.settings.coasterIntro)
                Stepper("ZMF presentation: \(settingsStore.settings.introSeconds)s", value: $settingsStore.settings.introSeconds, in: 3...60)
                    .disabled(settingsStore.settings.coasterIntro)
                Stepper("Countdown: \(settingsStore.settings.countdownSeconds)s", value: $settingsStore.settings.countdownSeconds, in: 3...30)
            }
            Section("YouTube trailer links") {
                TextField("YouTube URL — youtube.com/watch?v=…", text: $youtubeLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Display title", text: $youtubeTitle)
                Picker("Preview format", selection: $youtubeFormat) {
                    ForEach(TrailerPresentation.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                Button("Add YouTube trailer") {
                    guard let id = PreshowYouTubeTrailer.videoID(from: youtubeLink) else {
                        linkError = "Enter a public YouTube watch, Shorts or youtu.be HTTPS link."
                        return
                    }
                    guard !settingsStore.settings.youtubeTrailers.contains(where: { $0.videoID == id }) else {
                        linkError = "This trailer is already in your preshow list."
                        return
                    }
                    let title = youtubeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    settingsStore.settings.youtubeTrailers.append(PreshowYouTubeTrailer(
                        title: title.isEmpty ? "YouTube Trailer" : String(title.prefix(100)),
                        videoID: id, presentation: youtubeFormat))
                    youtubeLink = ""
                    youtubeTitle = ""
                    linkError = nil
                }.disabled(youtubeLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let linkError {
                    Text(linkError).font(.caption).foregroundStyle(.red)
                }
                ForEach(settingsStore.settings.youtubeTrailers) { trailer in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(trailer.title).font(.subheadline.bold())
                            Text(trailer.presentation.label + " · " + trailer.videoID)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            ForEach(TrailerPresentation.allCases) { format in
                                Button(format.label) { setType(trailer.id, format) }
                            }
                            Button("Remove", role: .destructive) {
                                settingsStore.settings.youtubeTrailers.removeAll { $0.id == trailer.id }
                            }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    }
                }.onMove { source, destination in
                    settingsStore.settings.youtubeTrailers.move(fromOffsets: source, toOffset: destination)
                }
                Text("Each presentation can play in 2D, 3D (red/cyan stereo window), 4DX or 4DX + 3D. YouTube does not let apps read its pixels, so 3D is a uniform stereo offset rather than the AI depth conversion used for your films. Paste official public YouTube links. Videos play through YouTube's embedded player; some uploaders disable embedding or require a tap to start. No video is downloaded. Use Next to skip unavailable previews.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                ForEach(files, id: \.self) { f in Text(f.lastPathComponent).font(.caption) }
                    .onDelete { idx in
                        for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                        reload()
                    }
                Button("Import trailer or preshow video…") { importing = true }
            } header: {
                Text("Trailers (\(files.count))")
            } footer: {
                Text("Import only trailers and preshow reels you're permitted to use (e.g. your own, or AMC material you have permission for). Nothing is downloaded or copied automatically. You can also drop .mp4/.mov files into Files → ZMF THEATERS+ → Trailers.")
            }
        }
        .navigationTitle("Trailer & Preshow Manager")
        .onAppear(perform: reload)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for u in urls {
                let access = u.startAccessingSecurityScopedResource()
                defer { if access { u.stopAccessingSecurityScopedResource() } }
                let dest = JSONStore.trailersDirectory.appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: u, to: dest)
            }
            reload()
        }
    }

    private func setType(_ id: UUID, _ format: TrailerPresentation) {
        guard let index = settingsStore.settings.youtubeTrailers.firstIndex(where: { $0.id == id }) else { return }
        settingsStore.settings.youtubeTrailers[index].presentation = format
    }

    private func reload() {
        files = ((try? FileManager.default.contentsOfDirectory(at: JSONStore.trailersDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mp4", "m4v", "mov"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

struct EconomyAdminView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Ticket prices (Z$)") {
                Stepper("Standard: Z$\(settingsStore.settings.standardPrice)", value: $settingsStore.settings.standardPrice, in: 0...2000, step: 5)
                Stepper("3D: Z$\(settingsStore.settings.threeDPrice)", value: $settingsStore.settings.threeDPrice, in: 0...2000, step: 5)
                Stepper("VIP: Z$\(settingsStore.settings.vipPrice)", value: $settingsStore.settings.vipPrice, in: 0...2000, step: 5)
            }
            Section("Concessions (Z$)") {
                Stepper("Popcorn: Z$\(settingsStore.settings.popcornPrice)", value: $settingsStore.settings.popcornPrice, in: 0...500)
                Stepper("Soda: Z$\(settingsStore.settings.sodaPrice)", value: $settingsStore.settings.sodaPrice, in: 0...500)
                Stepper("Candy: Z$\(settingsStore.settings.candyPrice)", value: $settingsStore.settings.candyPrice, in: 0...500)
            }
            Section("Rewards") {
                Stepper("Friday reward: Z$\(settingsStore.settings.weeklyReward)", value: $settingsStore.settings.weeklyReward, in: 0...20000, step: 500)
                Stepper("Daily attendance: Z$\(settingsStore.settings.dailyBonus)", value: $settingsStore.settings.dailyBonus, in: 0...2000, step: 50)
            }
            Section("Testing") {
                Toggle("Unlimited cash (admin testing)", isOn: $settingsStore.settings.unlimitedCash)
                Button("Grant Z$1,000") { model.wallet.credit(1000, memo: "Admin grant") }
            }
            Section { Text("ZMF CASH is fictional game money. There are no real purchases, payments, gambling or cash exchange.").font(.caption) }
        }
        .navigationTitle("Economy Manager")
        .onDisappear { model.refreshSignage() }
    }
}

struct GraphicsAdminView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Graphics") {
                Picker("Profile", selection: $settingsStore.settings.graphicsQuality) {
                    ForEach(GraphicsQuality.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Atmospheric fog", isOn: $settingsStore.settings.fogEnabled)
                Toggle("Projector beam & dust", isOn: $settingsStore.settings.projectorBeam)
                Toggle("Film grain", isOn: $settingsStore.settings.filmGrain)
                VStack(alignment: .leading) {
                    Text("Bloom: \(Int(settingsStore.settings.bloomStrength * 100))%")
                    Slider(value: $settingsStore.settings.bloomStrength, in: 0...1.5)
                }
                VStack(alignment: .leading) {
                    Text("Seated field of view: \(Int(settingsStore.settings.seatedFieldOfView))° (lower = bigger screen)")
                    Slider(value: $settingsStore.settings.seatedFieldOfView, in: 30...75)
                }
                VStack(alignment: .leading) {
                    Text("Screen light spill: \(Int(settingsStore.settings.screenBrightness * 100))%")
                    Slider(value: $settingsStore.settings.screenBrightness, in: 0...2)
                }
                Text("When the iPhone gets hot or Low Power Mode is on, the environment drops to 30 FPS and lower resolution automatically; the movie itself is never downscaled by the engine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Touch controls") {
                VStack(alignment: .leading) {
                    Text("Joystick size: \(Int(settingsStore.settings.joystickSize))")
                    Slider(value: $settingsStore.settings.joystickSize, in: 90...200)
                }
                VStack(alignment: .leading) {
                    Text("Look sensitivity: \(String(format: "%.1f", settingsStore.settings.lookSensitivity))×")
                    Slider(value: $settingsStore.settings.lookSensitivity, in: 0.3...3)
                }
                Toggle("Swap joystick and buttons", isOn: $settingsStore.settings.swapControls)
                Toggle("Hide controls while watching (tap to show)", isOn: $settingsStore.settings.autoHideControls)
            }
        }
        .navigationTitle("Graphics & Controls")
    }
}

struct PlaybackAdminView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Streaming") {
                Stepper("Max bitrate: \(settingsStore.settings.maxBitrateMbps) Mbps", value: $settingsStore.settings.maxBitrateMbps, in: 2...200, step: 2)
                TextField("Preferred subtitle language (e.g. eng)", text: $settingsStore.settings.preferredSubtitleLanguage)
                    .textInputAutocapitalization(.never)
                Text("Direct Play is used when the file is natively supported (MP4/MOV with H.264/HEVC). Anything else is remuxed or transcoded by your Jellyfin server to HLS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("TV") {
                Toggle("Continuous episode playback", isOn: $settingsStore.settings.autoplayNextEpisode)
                Stepper("Intermission: \(settingsStore.settings.intermissionSeconds)s", value: $settingsStore.settings.intermissionSeconds, in: 3...600, step: 5)
            }
            Section("Watch history") {
                ForEach(ResumeStore.shared.history.prefix(20), id: \.mediaId) { r in
                    HStack {
                        Text(r.mediaId.split(separator: ":").last.map(String.init) ?? r.mediaId).font(.caption2).lineLimit(1)
                        Spacer()
                        Text("\(formatTime(r.positionSeconds)) / \(formatTime(r.durationSeconds))").font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle("Playback")
    }
}

struct StereoAdminView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section {
                let d = model.renderer?.depth
                Label(d?.isAvailable == true ? "Depth model loaded (Depth Anything V2 Small, Core ML, Neural Engine)" : (d?.loadError ?? "Depth model not loaded"),
                      systemImage: d?.isAvailable == true ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.caption)
                Text("Buy a 3D ticket for any film and it is converted live: monocular depth → left/right view synthesis with edge-aware dilation → temporal stabilisation → red/cyan anaglyph on the GPU. Converted 3D approximates depth; it is not native stereoscopic mastering.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Depth & stereo") {
                slider("Depth intensity", $settingsStore.settings.depthIntensity, 0.2...2.0, "%.1f×")
                slider("Stereo separation", $settingsStore.settings.stereoSeparation, 0.003...0.03, "%.3f")
                slider("Convergence (screen plane)", $settingsStore.settings.convergence, 0...1, "%.2f")
                slider("Ghosting reduction", $settingsStore.settings.ghostingReduction, 0...1, "%.2f")
            }
            Section("Performance") {
                Picker("Preset", selection: $settingsStore.settings.depthUpdatesPerSecond) {
                    Text("Battery (4 Hz)").tag(4.0)
                    Text("Balanced (8 Hz)").tag(8.0)
                    Text("Smooth (15 Hz)").tag(15.0)
                    Text("Max (30 Hz)").tag(30.0)
                }
                Text("Between depth updates the stabilised map is reused, so the picture itself always runs at full frame rate.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("3D Cinema Settings")
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(String(format: fmt, value.wrappedValue))")
            Slider(value: value, in: range)
        }
    }
}

struct FourDXAdminView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section {
                Text(FourDX.teaser(settings: settingsStore.settings)).font(.headline).foregroundStyle(.cyan)
                Text("4DX is permanently available. This development build uses conservative picture-motion analysis. Semantic event detection and the expanded effect library are not implemented yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("Effects") {
                VStack(alignment: .leading) {
                    Text("Intensity & motion sensitivity: \(Int(settingsStore.settings.fourDXIntensity * 100))%")
                    Slider(value: $settingsStore.settings.fourDXIntensity, in: 0...1)
                }
                Toggle("iPhone haptics (Taptic Engine rumble)", isOn: $settingsStore.settings.fourDXHaptics)
                VStack(alignment: .leading) {
                    Text("Phone haptic intensity: \(Int(settingsStore.settings.fourDXHapticStrength * 100))%")
                    Slider(value: $settingsStore.settings.fourDXHapticStrength, in: 0...1)
                    Text("Sharper detected hits, faster vibration updates, smoother ambience. Limited by the iPhone Taptic Engine; not a physical chair or vest.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("Virtual chair travel: \(Int(settingsStore.settings.fourDXSeatTravel * 100))%")
                    Slider(value: $settingsStore.settings.fourDXSeatTravel, in: 0...1.5)
                }
                Text("Seat acceleration and banking are gentle and bounded; physical motion chairs are not connected.")
                    .font(.caption2).foregroundStyle(.secondary)
                Toggle("Mist (virtual atmosphere)", isOn: $settingsStore.settings.fourDXVirtualMist)
                Toggle("Snow particles", isOn: $settingsStore.settings.fourDXVirtualSnow)
                Toggle("Floating ash particles", isOn: $settingsStore.settings.fourDXVirtualAsh)
                Toggle("Volumetric fog", isOn: $settingsStore.settings.fourDXVirtualFog)
                Toggle("Water spray & mist on screen", isOn: $settingsStore.settings.fourDXScreenEffects)
                Toggle("Light flashes (ride & concert beats)", isOn: $settingsStore.settings.fourDXScreenFlashes)
                Text("Screen effects draw water droplets, mist, wind streaks and vibration over your view while seated in a 4DX screening. Flashes are off by default; leave them off if you are sensitive to flashing light.")
                    .font(.caption2).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Atmosphere intensity: \(Int(settingsStore.settings.fourDXAtmosphereStrength * 100))%")
                    Slider(value: $settingsStore.settings.fourDXAtmosphereStrength, in: 0...1)
                }
                Text("Films: the chair follows the picture's camera motion in real time (pans bank, tilts pitch, push-ins surge, shake vibrates), and the soundtrack is analysed live for sharp hits (stabs, punches, shots), booms (explosions) and debris, each with its own haptics, jolts, shockwave, embers and smoke. At 100% intensity it is very motion-sensitive. Sound analysis needs a direct-play file; transcoded streams use picture motion only. Sounds are classified acoustically, so a punch and a stab feel alike. Presentations and YouTube use the player clock. No physical mist, snow or smoke hardware is activated.")
                    .font(.caption2).foregroundStyle(.secondary)
                Stepper("4DX ticket: Z$\(settingsStore.settings.fourDXPrice)", value: $settingsStore.settings.fourDXPrice, in: 0...2000, step: 25)
            }
            Section("bHaptics TactSuit Air") {
                Text("The official bHaptics Swift SDK supports direct Bluetooth LE on iOS, but it is not integrated into this build. This toggle controls the iPhone Taptic Engine only. Windows vest output is disabled pending protocol and hardware validation.")
                    .font(.caption2)
            }
            Section("Testing") {
                Toggle("Legacy preview override (no longer required)", isOn: $settingsStore.settings.fourDXForcePreview)
            }
        }
        .navigationTitle("Immersive 4DX")
    }
}

