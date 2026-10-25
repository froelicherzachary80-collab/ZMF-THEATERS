import SwiftUI

struct TicketPurchaseView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: MediaLibrary
    @EnvironmentObject var wallet: Wallet
    @Environment(\.dismiss) private var dismiss

    let item: MediaItem
    let room: CinemaRoom
    let featured: Bool
    var episodeQueue: [String] = []

    @State private var roomId: Int = 0
    @State private var showtimeId: String?   // nil = private screening now
    @State private var row: Int?
    @State private var seat: Int?
    @State private var format: ScreeningFormat = .standard2D
    @State private var formatChosen = false

    private var selectedRoom: CinemaRoom { CinemaRooms.room(roomId == 0 ? room.id : roomId) }
    private var showtimes: [Showtime] { featured ? model.nextShowtimes(selectedRoom.id, limit: 8) : [] }
    private var chosenShowtime: Showtime? { showtimes.first { $0.id == showtimeId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                showtimePicker
                formatPicker
                roomPicker
                SeatMap(room: selectedRoom, taken: model.takenSeats(room: selectedRoom.id, showtime: chosenShowtime?.featureStart),
                        row: $row, seat: $seat)
                purchaseBar
            }
            .padding()
        }
        .navigationTitle("Tickets")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if roomId == 0 { roomId = room.id }
            if !formatChosen { format = room.is3D ? .anaglyph3D : .standard2D }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PosterView(item: item, width: 70)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle).font(.title3.bold())
                Text("ROOM \(selectedRoom.code) · \(selectedRoom.name.uppercased())").font(.caption.bold()).foregroundStyle(.orange)
                Text(selectedRoom.is3D ? "3D auditorium" : "2D auditorium").font(.caption2).foregroundStyle(.secondary)
                if !library.isAvailable(item) {
                    Label("This title's server is offline right now", systemImage: "wifi.slash").font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    private var showtimePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Showing").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    chip(label: "Private screening\nStarts when you sit", selected: showtimeId == nil) { showtimeId = nil }
                    ForEach(showtimes) { s in
                        let f = ShowtimeScheduler.timeFormatter(model.settings)
                        chip(label: "\(f.string(from: s.featureStart))\nPreshow \(f.string(from: s.preshowStart))", selected: showtimeId == s.id) { showtimeId = s.id }
                    }
                }
            }
            Text("Scheduled tickets never expire on you — the screening starts whenever you take your seat.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Format").font(.headline)
            HStack {
                ForEach(ScreeningFormat.allCases) { f in
                    let locked = f == .fourDX && !model.fourDXAvailable
                    Button {
                        guard !locked else { return }
                        format = f
                        formatChosen = true
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: locked ? "lock.fill" : f.symbol)
                            Text(f.label).font(.caption.bold())
                            Text(priceLabel(f)).font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(format == f ? Color.orange : Color.gray.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(format == f ? Color.black : (locked ? Color.gray : Color.primary))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(formatNote).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func priceLabel(_ f: ScreeningFormat) -> String {
        if f == .fourDX && !model.fourDXAvailable { return "Oct 27–28" }
        return "Z$\(model.price(room: selectedRoom, row: 0, format: f).0)+"
    }

    private var formatNote: String {
        switch format {
        case .standard2D: return "The film plays exactly as mastered."
        case .anaglyph3D: return "ZMF DepthCinema AI estimates depth on-device and converts the film to red/cyan 3D. Wear red (left) / cyan (right) glasses. Converted 3D is an approximation, not native 3D."
        case .fourDX: return "4DX preview: motion seat, rumble, strobes and fog driven by the on-screen action. On Windows it also drives a bHaptics TactSuit Air."
        }
    }

    private var roomPicker: some View {
        HStack {
            Text("Auditorium").font(.headline)
            Spacer()
            Picker("Auditorium", selection: $roomId) {
                ForEach(CinemaRooms.all) { r in
                    Text("\(r.code) \(r.name)\(r.id == room.id ? " ★" : "")").tag(r.id)
                }
            }
            .pickerStyle(.menu)
        }
        .onChange(of: roomId) { _, _ in row = nil; seat = nil }
    }

    private var purchaseBar: some View {
        let price = row.map { model.price(room: selectedRoom, row: $0, format: format) }
        return HStack {
            VStack(alignment: .leading) {
                if let row, let seat, let price {
                    Text("Seat \(Seating.rowLetter(row))\(seat + 1) · \(format.label)\(price.1 == .vip ? " · VIP" : "")").font(.headline)
                    Text("Z$\(price.0) · balance Z$\(wallet.balance)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Choose a seat").font(.headline)
                }
            }
            Spacer()
            Button {
                guard let row, let seat else { return }
                if model.purchase(item: item, room: selectedRoom, row: row, seat: seat, showtime: chosenShowtime, episodeQueue: episodeQueue, format: format) != nil {
                    dismiss()
                }
            } label: {
                Label("Buy ticket", systemImage: "ticket.fill").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(row == nil || seat == nil)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func chip(label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.caption.bold()).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(selected ? Color.orange : Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct SeatMap: View {
    let room: CinemaRoom
    let taken: Set<Int>
    @Binding var row: Int?
    @Binding var seat: Int?

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [.white, .gray], startPoint: .top, endPoint: .bottom))
                .frame(height: 6).padding(.horizontal, 30)
            Text("SCREEN").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(0..<Seating.rows, id: \.self) { r in
                HStack(spacing: 5) {
                    Text(Seating.rowLetter(r)).font(.caption.bold()).frame(width: 16)
                    Spacer(minLength: 14)
                    ForEach(0..<Seating.seatsPerRow, id: \.self) { s in
                        seatButton(r, s)
                    }
                    Spacer(minLength: 14)
                    Text(Seating.rowLetter(r)).font(.caption.bold()).frame(width: 16)
                }
            }
            HStack(spacing: 14) {
                legend(.gray.opacity(0.4), "Available")
                legend(.yellow.opacity(0.5), "VIP recliner")
                legend(.orange, "Selected")
                legend(.red.opacity(0.4), "Taken")
            }
            .font(.caption2)
            .padding(.top, 4)
        }
    }

    private func seatButton(_ r: Int, _ s: Int) -> some View {
        let isTaken = taken.contains(r * 100 + s)
        let isSelected = row == r && seat == s
        let vip = Seating.vipRows.contains(r)
        let fill: Color = isSelected ? .orange : (isTaken ? .red.opacity(0.4) : (vip ? .yellow.opacity(0.5) : .gray.opacity(0.4)))
        return Button {
            guard !isTaken else { return }
            row = r; seat = s
        } label: {
            Text("\(s + 1)").font(.system(size: 10, weight: .bold))
                .frame(width: 30, height: 26)
                .background(fill, in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isTaken)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 12, height: 10); Text(t) }
    }
}
