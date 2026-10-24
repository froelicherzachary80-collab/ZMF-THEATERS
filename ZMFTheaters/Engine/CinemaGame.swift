import Foundation
import Combine
import simd

enum CameraMode: String, CaseIterable {
    case firstPerson, thirdPerson
}

/// HUD state published at a throttled rate so SwiftUI isn't re-rendered every frame.
struct HUDInfo: Equatable {
    var zoneName = "Lobby"
    var interactable: Interactable?
    var prompt: String?
    var guidanceAngle: Float?   // radians relative to view direction, nil = no target
    var guidanceDistance: Float = 0
    var guidanceLabel: String?
    var seated = false
}

/// Player state, movement, collision and interaction for the 3D cinema.
@MainActor
final class CinemaGame: ObservableObject {
    @Published private(set) var hud = HUDInfo()
    @Published var cameraMode: CameraMode = .firstPerson

    // Input written by the touch controls.
    var moveInput = Vec2.zero
    var lookDelta = Vec2.zero

    // Player state
    private(set) var position = Vec3(CinemaWorld.spawn.x, 0, CinemaWorld.spawn.y)
    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0
    private(set) var seatedAt: (room: Int, row: Int, seat: Int)?
    private(set) var reclined = false
    private var sitBlend: Float = 0           // 0 standing → 1 seated
    private var seatYawOffset: Float = 0
    private var standPosition = Vec3.zero
    private var walkPhase: Float = 0
    private(set) var doorOpen: [Float] = Array(repeating: 0, count: 13)
    private var hudTimer: Float = 0
    private(set) var time: Float = 0

    /// Rooms the player may enter (active ticket or admin override). Set by AppModel.
    var unlockedRooms: Set<Int> = []
    var allDoorsUnlocked = false
    /// The seat the player's ticket points to, for guidance and the SIT prompt.
    var seatTarget: (room: Int, row: Int, seat: Int)?
    var lookSensitivity: Float = 1

    var zone: Zone { CinemaWorld.zone(at: Vec2(position.x, position.z)) }
    var isSeated: Bool { seatedAt != nil }

    func isUnlocked(_ id: Int) -> Bool { allDoorsUnlocked || unlockedRooms.contains(id) }

    // MARK: Camera

    struct CameraState {
        var eye: Vec3
        var target: Vec3
    }

    func camera() -> CameraState {
        let ground = position.y
        if let s = seatedAt {
            let seat = CinemaWorld.seatPosition(room: s.room, row: s.row, seat: s.seat)
            let back = -forwardVector(yaw: CinemaWorld.screenYaw(s.room))
            let recline: Float = reclined ? 1 : 0
            let seatedEye = seat + Vec3(0, 1.12 - 0.12 * recline, 0) + back * (0.18 + 0.2 * recline)
            let standEye = standPosition + Vec3(0, CinemaWorld.eyeHeight, 0)
            let t = smoothstep(sitBlend)
            // Subtle breathing so the seated view feels like a body, not a tripod.
            let breathe = Vec3(0, sinf(time * 1.35) * 0.006, 0) + back * (sinf(time * 0.7) * 0.004)
            let eye = standEye + (seatedEye - standEye) * t + breathe * t
            let dir = forwardVector(yaw: yaw, pitch: pitch + 0.08 * recline)
            return CameraState(eye: eye, target: eye + dir)
        }
        let bob = sinf(walkPhase) * 0.035 * min(1, simd_length(moveInput))
        let eye = Vec3(position.x, ground + CinemaWorld.eyeHeight + bob, position.z)
        let dir = forwardVector(yaw: yaw, pitch: pitch)
        if cameraMode == .thirdPerson {
            let back = Vec3(-dir.x, 0, -dir.z)
            let len = max(0.001, simd_length(back))
            var cam = eye + back / len * 3.2 + Vec3(0, 0.6, 0)
            // Pull the camera in if it would leave the walkable space.
            if !CinemaWorld.isWalkable(Vec2(cam.x, cam.z), radius: 0.1, doorOpen: { _ in true }) {
                cam = eye + back / len * 0.8 + Vec3(0, 0.4, 0)
            }
            return CameraState(eye: cam, target: eye + dir * 2)
        }
        return CameraState(eye: eye, target: eye + dir)
    }

    private func smoothstep(_ x: Float) -> Float { let t = max(0, min(1, x)); return t * t * (3 - 2 * t) }

    // MARK: Update

    func update(dt: Float) {
        time += dt
        // Look
        let look = lookDelta * 0.005 * lookSensitivity
        lookDelta = .zero
        if let s = seatedAt {
            seatYawOffset = max(-1.3, min(1.3, seatYawOffset - look.x))
            yaw = CinemaWorld.screenYaw(s.room) + seatYawOffset
            pitch = max(-0.6, min(0.7, pitch - look.y))
            sitBlend = min(1, sitBlend + dt * 1.4)
        } else {
            yaw = wrapAngle(yaw - look.x)
            pitch = max(-1.2, min(1.2, pitch - look.y))
            sitBlend = max(0, sitBlend - dt * 2)
            move(dt: dt)
        }

        // Doors slide open when an unlocked room's door is approached.
        // Leaving is always allowed, so a door also opens for a player inside
        // its room or standing in its doorway.
        let p2 = Vec2(position.x, position.z)
        let here = zone
        for id in 1...12 {
            let d = simd_distance(p2, CinemaWorld.doorFront(id))
            let base = CinemaWorld.roomBaseZ(id)
            let inDoorway = abs(p2.x) > 3.8 && abs(p2.x) < 5.3 && (id <= 6) == (p2.x < 0)
                && p2.y > base + CinemaWorld.doorZ0 && p2.y < base + CinemaWorld.doorZ1
            let allowed = isUnlocked(id) || here == .room(id) || inDoorway
            let target: Float = (allowed && d < 5) ? 1 : 0
            doorOpen[id] += (target - doorOpen[id]) * min(1, dt * 4)
        }

        hudTimer += dt
        if hudTimer > 0.1 {
            hudTimer = 0
            refreshHUD()
        }
    }

    private func move(dt: Float) {
        let mag = simd_length(moveInput)
        guard mag > 0.05 else { return }
        let fwd = forwardVector(yaw: yaw)
        let right = simd_normalize(simd_cross(fwd, Vec3(0, 1, 0)))
        let speed: Float = 3.4
        let v = (fwd * moveInput.y + right * moveInput.x) * speed * dt
        let p = Vec2(position.x, position.z)
        let canPass: (Int) -> Bool = { [unowned self] id in self.doorOpen[id] > 0.6 }
        var next = p + Vec2(v.x, v.z)
        if !CinemaWorld.isWalkable(next, doorOpen: canPass) {
            let tryX = p + Vec2(v.x, 0)
            let tryZ = p + Vec2(0, v.z)
            if CinemaWorld.isWalkable(tryX, doorOpen: canPass) { next = tryX }
            else if CinemaWorld.isWalkable(tryZ, doorOpen: canPass) { next = tryZ }
            else { next = p }
        }
        let g = CinemaWorld.groundHeight(at: next)
        position = Vec3(next.x, position.y + (g - position.y) * min(1, dt * 10), next.y)
        walkPhase += dt * 9 * mag
    }

    // MARK: Actions

    func sit(room: Int, row: Int, seat: Int) {
        standPosition = position
        seatedAt = (room, row, seat)
        seatYawOffset = 0
        pitch = -0.02
        yaw = CinemaWorld.screenYaw(room)
        refreshHUD()
    }

    func stand() {
        guard let s = seatedAt else { return }
        let seat = CinemaWorld.seatPosition(room: s.room, row: s.row, seat: s.seat)
        // Step out into the row's aisle-side space behind the seat.
        let back = -forwardVector(yaw: CinemaWorld.screenYaw(s.room))
        position = Vec3(seat.x + back.x * 0.9, seat.y, seat.z)
        standPosition = position
        seatedAt = nil
        reclined = false
        sitBlend = 0
        refreshHUD()
    }

    func toggleRecline() { if isSeated { reclined.toggle() } }

    /// Places the player directly (used by the `-zmfShot` launch argument for screenshots).
    func debugPlace(_ p: Vec3, yaw: Float, pitch: Float) {
        seatedAt = nil
        position = p
        self.yaw = yaw
        self.pitch = pitch
        refreshHUD()
    }

    func teleportToLobby() {
        seatedAt = nil
        position = Vec3(CinemaWorld.spawn.x, 0, CinemaWorld.spawn.y)
        yaw = 0; pitch = 0
        refreshHUD()
    }

    // MARK: HUD

    private func refreshHUD() {
        var h = HUDInfo()
        let p2 = Vec2(position.x, position.z)
        let z = zone
        switch z {
        case .lobby: h.zoneName = "Lobby"
        case .hall: h.zoneName = "Auditorium Hall"
        case .room(let id): h.zoneName = "Room \(CinemaRooms.room(id).code) · \(CinemaRooms.room(id).name)"
        }
        h.seated = isSeated
        if !isSeated {
            h.interactable = CinemaWorld.nearestInteractable(at: p2, zone: z, seatTarget: seatTarget)
            switch h.interactable {
            case .boxOffice?: h.prompt = "Box Office — buy tickets"
            case .kiosk?: h.prompt = "Ticket kiosk"
            case .concession?: h.prompt = "Concessions — snacks & drinks"
            case .door(let id)?:
                let r = CinemaRooms.room(id)
                h.prompt = isUnlocked(id) ? "Room \(r.code) \(r.name) — ticket accepted" : "Room \(r.code) \(r.name) — ticket required"
            case .seat(_, let row, let seat)?: h.prompt = "Your seat \(Seating.rowLetter(row))\(seat + 1) — tap SIT"
            case nil: break
            }
        }

        // Navigation guidance toward the ticketed seat.
        if let t = seatTarget, !isSeated {
            let goal: Vec2
            let label: String
            if case .room(let id) = z, id == t.room {
                let s = CinemaWorld.seatPosition(room: t.room, row: t.row, seat: t.seat)
                goal = Vec2(s.x, s.z)
                label = "Seat \(Seating.rowLetter(t.row))\(t.seat + 1)"
            } else if case .room = z {
                // Wrong room: head back out of its door first.
                if case .room(let cur) = z {
                    let rr = CinemaWorld.roomRect(cur)
                    goal = Vec2(cur <= 6 ? rr.x1 : rr.x0, rr.z0 + 7)
                } else { goal = p2 }
                label = "Exit to the hall"
            } else if case .hall = z {
                goal = CinemaWorld.doorFront(t.room)
                label = "Room \(CinemaRooms.room(t.room).code)"
            } else {
                goal = Vec2(0, 20)
                label = "Auditorium Hall → Room \(CinemaRooms.room(t.room).code)"
            }
            let d = goal - p2
            let fwd = forwardVector(yaw: yaw)
            let angTarget = atan2f(d.x, d.y)
            let angView = atan2f(fwd.x, fwd.z)
            h.guidanceAngle = wrapAngle(angTarget - angView)
            h.guidanceDistance = simd_length(d)
            h.guidanceLabel = label
        }
        if h != hud { hud = h }
    }
}
