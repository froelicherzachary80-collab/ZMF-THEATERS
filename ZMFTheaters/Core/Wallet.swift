import Foundation
import Combine

enum Snack: String, Codable, CaseIterable, Identifiable {
    case popcorn, soda, candy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .popcorn: return "Popcorn"
        case .soda: return "Soda"
        case .candy: return "Candy"
        }
    }
    var symbol: String {
        switch self {
        case .popcorn: return "popcorn.fill"
        case .soda: return "cup.and.saucer.fill"
        case .candy: return "birthday.cake.fill"
        }
    }
    func price(_ s: AppSettings) -> Int {
        switch self {
        case .popcorn: return s.popcornPrice
        case .soda: return s.sodaPrice
        case .candy: return s.candyPrice
        }
    }
}

/// ZMF CASH (Z$). Fictional, device-local game currency — there is no payment
/// processing, no real-money exchange and no gambling of any kind.
@MainActor
final class Wallet: ObservableObject {
    struct State: Codable {
        var balance = 5000
        var transactions: [WalletTransaction] = [WalletTransaction(amount: 5000, memo: "Welcome to ZMF THEATERS+")]
        var tickets: [Ticket] = []
        var snacks: [String: Int] = [:]
        var lastWeeklyCheck = Date()
        var lastDailyBonusDay = ""
    }

    @Published private(set) var state: State
    private let store: JSONStore

    init(store: JSONStore = .shared) {
        self.store = store
        self.state = store.load(State.self, "wallet") ?? State()
    }

    var balance: Int { state.balance }
    var tickets: [Ticket] { state.tickets }
    var activeTickets: [Ticket] { state.tickets.filter { $0.status == .active } }
    var transactions: [WalletTransaction] { state.transactions }

    func snackCount(_ s: Snack) -> Int { state.snacks[s.rawValue] ?? 0 }

    private func persist() { store.save(state, "wallet") }

    private func record(_ amount: Int, _ memo: String) {
        state.transactions.insert(WalletTransaction(amount: amount, memo: memo), at: 0)
        if state.transactions.count > 500 { state.transactions.removeLast(state.transactions.count - 500) }
    }

    func canAfford(_ amount: Int, settings: AppSettings) -> Bool {
        settings.unlimitedCash || state.balance >= amount
    }

    @discardableResult
    func spend(_ amount: Int, memo: String, settings: AppSettings) -> Bool {
        guard canAfford(amount, settings: settings) else { return false }
        if !settings.unlimitedCash { state.balance -= amount }
        record(-amount, settings.unlimitedCash ? memo + " (admin unlimited)" : memo)
        persist()
        return true
    }

    func credit(_ amount: Int, memo: String) {
        state.balance += amount
        record(amount, memo)
        persist()
    }

    func issue(_ ticket: Ticket, settings: AppSettings) -> Bool {
        guard spend(ticket.price, memo: "Ticket · \(ticket.title) · Room \(String(format: "%02d", ticket.roomId)) \(ticket.seatLabel)", settings: settings) else { return false }
        state.tickets.insert(ticket, at: 0)
        persist()
        return true
    }

    func refund(_ ticket: Ticket) {
        guard let i = state.tickets.firstIndex(where: { $0.id == ticket.id }), state.tickets[i].status == .active else { return }
        state.tickets[i].status = .refunded
        credit(ticket.price, memo: "Refund · \(ticket.title)")
    }

    func markUsed(_ ticket: Ticket) {
        guard let i = state.tickets.firstIndex(where: { $0.id == ticket.id }) else { return }
        state.tickets[i].status = .used
        persist()
    }

    func buySnack(_ snack: Snack, settings: AppSettings) -> Bool {
        guard spend(snack.price(settings), memo: "Concessions · \(snack.label)", settings: settings) else { return false }
        state.snacks[snack.rawValue, default: 0] += 1
        persist()
        return true
    }

    func consumeSnack(_ snack: Snack) -> Bool {
        guard snackCount(snack) > 0 else { return false }
        state.snacks[snack.rawValue, default: 0] -= 1
        persist()
        return true
    }

    /// Grants the daily attendance bonus and one weekly reward for every Friday
    /// that has passed since the last check (capped at four to stay sane).
    func applyRewards(now: Date = Date(), settings: AppSettings) -> [String] {
        var messages: [String] = []
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = settings.timeZone

        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = settings.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: now)
        if state.lastDailyBonusDay != today, settings.dailyBonus > 0 {
            state.lastDailyBonusDay = today
            credit(settings.dailyBonus, memo: "Daily attendance bonus")
            messages.append("Daily bonus +Z$\(settings.dailyBonus)")
        }

        var fridays = 0
        var cursor = cal.startOfDay(for: state.lastWeeklyCheck)
        while let next = cal.date(byAdding: .day, value: 1, to: cursor), next <= now {
            if cal.component(.weekday, from: next) == 6 { fridays += 1 }
            cursor = next
        }
        state.lastWeeklyCheck = now
        let grants = min(fridays, 4)
        if grants > 0 {
            for _ in 0..<grants { credit(settings.weeklyReward, memo: "Friday cinema reward") }
            messages.append("Friday reward +Z$\(settings.weeklyReward * grants)")
        }
        persist()
        return messages
    }
}
