import SwiftUI

struct WalletView: View {
    @EnvironmentObject var wallet: Wallet
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Z$\(wallet.balance)").font(.system(size: 40, weight: .black)).foregroundStyle(.yellow)
                        Text("ZMF CASH · fictional game money").font(.caption).foregroundStyle(.secondary)
                        Text("Friday reward Z$\(settingsStore.settings.weeklyReward) · daily attendance Z$\(settingsStore.settings.dailyBonus)").font(.caption2)
                        if settingsStore.settings.unlimitedCash { Text("Unlimited cash (admin testing) is ON").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                Section("Snacks you're carrying") {
                    ForEach(Snack.allCases) { s in
                        Label("\(s.label) × \(wallet.snackCount(s))", systemImage: s.symbol)
                    }
                }
                Section("Purchase history") {
                    ForEach(wallet.transactions) { t in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(t.memo).font(.caption)
                                Text(t.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(t.amount >= 0 ? "+Z$\(t.amount)" : "−Z$\(-t.amount)")
                                .font(.caption.bold().monospacedDigit())
                                .foregroundStyle(t.amount >= 0 ? .green : .primary)
                        }
                    }
                }
            }
            .navigationTitle("Wallet")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct ConcessionView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wallet: Wallet
    @EnvironmentObject var settingsStore: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Grab something for the show. Snacks travel with you into the auditorium — tap SNACK while seated to enjoy them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Snack.allCases) { s in
                    HStack {
                        Image(systemName: s.symbol).font(.title2).foregroundStyle(.orange).frame(width: 40)
                        VStack(alignment: .leading) {
                            Text(s.label).font(.headline)
                            Text("Z$\(s.price(settingsStore.settings)) · carrying \(wallet.snackCount(s))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Buy") {
                            if wallet.buySnack(s, settings: settingsStore.settings) {
                                model.flash("\(s.label) purchased!")
                            } else {
                                model.flash("Not enough ZMF CASH.")
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                    }
                }
                Section { Text("Slushies, nachos, hot food and ice cream counters are on display in the lobby; they become orderable with AI staff in v0.3.").font(.caption2).foregroundStyle(.secondary) }
            }
            .navigationTitle("Concessions")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

/// Top-down schematic of the building with the player and ticketed room.
struct CinemaMapView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var game: CinemaGame
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Canvas { ctx, size in
                // World x ∈ [-31, 31], z ∈ [-1, 112] rotated so the hall runs left → right.
                let sx = size.width / 116, sz = size.height / 64
                let k = min(sx, sz)
                let ox = (size.width - 116 * k) / 2, oy = (size.height - 64 * k) / 2
                func pt(_ x: Float, _ z: Float) -> CGPoint { CGPoint(x: ox + CGFloat(z + 2) * k, y: oy + CGFloat(x + 32) * k) }
                func rect(_ r: Rect2) -> CGRect {
                    let a = pt(r.x0, r.z0), b = pt(r.x1, r.z1)
                    return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                }
                ctx.fill(Path(rect(CinemaWorld.lobby)), with: .color(.brown.opacity(0.5)))
                ctx.draw(Text("LOBBY").font(.caption2.bold()), at: CGPoint(x: rect(CinemaWorld.lobby).midX, y: rect(CinemaWorld.lobby).midY))
                ctx.fill(Path(rect(Rect2(x0: -4, x1: 4, z0: 20, z1: CinemaWorld.hallZ1))), with: .color(.red.opacity(0.35)))
                let target = model.guidedTicket?.roomId
                for room in CinemaRooms.all {
                    let r = rect(CinemaWorld.roomRect(room.id))
                    let color: Color = room.id == target ? .orange : (game.isUnlocked(room.id) ? .green.opacity(0.5) : .gray.opacity(0.35))
                    ctx.fill(Path(r), with: .color(color))
                    ctx.stroke(Path(r), with: .color(.white.opacity(0.4)))
                    ctx.draw(Text("\(room.code)\n\(room.name)").font(.system(size: 8, weight: .bold)), at: CGPoint(x: r.midX, y: r.midY))
                }
                let p = pt(game.position.x, game.position.z)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.yellow))
                let f = forwardVector(yaw: game.yaw)
                let tip = pt(game.position.x + f.x * 3, game.position.z + f.z * 3)
                var heading = Path(); heading.move(to: p); heading.addLine(to: tip)
                ctx.stroke(heading, with: .color(.yellow), lineWidth: 2)
            }
            .background(Color.black)
            .navigationTitle("Cinema Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Return to lobby") { game.teleportToLobby(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
