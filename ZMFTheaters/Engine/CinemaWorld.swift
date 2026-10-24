import simd

struct PointLight {
    var position: Vec3
    var range: Float
    var color: Vec3
    var intensity: Float
    /// Auditorium the light belongs to (dimmed by the house-light level), nil for lobby/hall.
    var roomId: Int?
}

struct Rect2 {
    var x0: Float, x1: Float, z0: Float, z1: Float
    func contains(_ p: Vec2) -> Bool { p.x >= x0 && p.x <= x1 && p.y >= z0 && p.y <= z1 }
    func inset(_ d: Float) -> Rect2 { Rect2(x0: x0 + d, x1: x1 - d, z0: z0 + d, z1: z1 - d) }
}

enum Zone: Equatable {
    case lobby, hall, room(Int)
}

enum Interactable: Equatable {
    case boxOffice
    case kiosk
    case concession
    case door(Int)
    case seat(room: Int, row: Int, seat: Int)
}

/// Static layout of the ZMF THEATERS+ building.
///
/// World axes: +Y up, +Z runs from the lobby entrance (z=0) up the auditorium
/// hall (z=20…111). Rooms 01–06 open off the west side of the hall (x<0),
/// 07–12 off the east side (x>0). Each auditorium is authored in local space
/// (x=0 at the screen wall, x=25.8 at the hall-side back wall, z=0…14 across)
/// and mapped into the world by `transform(room:)`.
enum CinemaWorld {
    static let lobby = Rect2(x0: -16, x1: 16, z0: 0, z1: 20)
    static let hallHalfWidth: Float = 4
    static let hallZ0: Float = 20
    static let roomSpacing: Float = 15
    static let firstRoomZ: Float = 21
    static var hallZ1: Float { firstRoomZ + 6 * roomSpacing }
    static let roomDepth: Float = 25.8
    static let roomWidth: Float = 14
    static let roomCeiling: Float = 6.5
    static let roomFloorMin: Float = -2.4
    static let lobbyCeiling: Float = 9
    static let hallCeiling: Float = 4.5
    static let doorZ0: Float = 6, doorZ1: Float = 8, doorHeight: Float = 2.6
    static let eyeHeight: Float = 1.65
    static let spawn = Vec2(0, 3)

    // MARK: Seating geometry (local space)

    static func rowX(_ r: Int) -> Float { 8 + Float(r) * 1.6 }
    static func rowFloor(_ r: Int) -> Float { -Float(7 - r) * 0.3 }
    static func seatZ(_ s: Int) -> Float { 7 + (Float(s) - 3.5) * 1.2 }

    static func localGround(_ lx: Float) -> Float {
        if lx >= 20.0 { return 0 }
        if lx < 7.2 { return roomFloorMin }
        let r = max(0, min(7, Int((lx - 7.2) / 1.6)))
        return rowFloor(r)
    }

    static func roomBaseZ(_ id: Int) -> Float { firstRoomZ + Float((id - 1) % 6) * roomSpacing }

    static func transform(room id: Int) -> RoomTransform {
        let z0 = roomBaseZ(id)
        return id <= 6 ? RoomTransform(originX: -30, signX: 1, originZ: z0) : RoomTransform(originX: 30, signX: -1, originZ: z0)
    }

    static func roomRect(_ id: Int) -> Rect2 {
        let z0 = roomBaseZ(id)
        return id <= 6 ? Rect2(x0: -30, x1: -4.2, z0: z0, z1: z0 + roomWidth) : Rect2(x0: 4.2, x1: 30, z0: z0, z1: z0 + roomWidth)
    }

    static func toLocal(_ p: Vec2, room id: Int) -> Vec2 {
        let t = transform(room: id)
        return Vec2((p.x - t.originX) * t.signX, p.y - t.originZ)
    }

    /// Hall-side point in front of a room's door.
    static func doorFront(_ id: Int) -> Vec2 {
        let z = roomBaseZ(id) + (doorZ0 + doorZ1) / 2
        return Vec2(id <= 6 ? -3.0 : 3.0, z)
    }

    static func seatPosition(room id: Int, row: Int, seat: Int) -> Vec3 {
        transform(room: id).point(Vec3(rowX(row), rowFloor(row), seatZ(seat)))
    }

    /// World-space yaw that faces the screen of a room.
    static func screenYaw(_ id: Int) -> Float { id <= 6 ? -.pi / 2 : .pi / 2 }

    static func screenCenter(_ id: Int) -> Vec3 { transform(room: id).point(Vec3(0.35, 1.2, 7)) }
    static func screenNormal(_ id: Int) -> Vec3 { transform(room: id).normal(Vec3(1, 0, 0)) }
    static let screenSize = Vec2(12, 5.2)

    static func zone(at p: Vec2) -> Zone {
        for id in 1...12 where roomRect(id).contains(p) { return .room(id) }
        if p.y >= hallZ0 && abs(p.x) <= hallHalfWidth + 0.5 { return .hall }
        return .lobby
    }

    static func groundHeight(at p: Vec2) -> Float {
        if case .room(let id) = zone(at: p) { return localGround(toLocal(p, room: id).x) }
        return 0
    }

    // MARK: Collision

    static let lobbyObstacles: [Rect2] = [
        Rect2(x0: -14.5, x1: -7.5, z0: 8.6, z1: 10.4),  // box office counter
        Rect2(x0: 7.5, x1: 14.5, z0: 8.6, z1: 10.4),    // concession counter
        Rect2(x0: -6.5, x1: -5.5, z0: 13.5, z1: 14.5),  // kiosks
        Rect2(x0: 5.5, x1: 6.5, z0: 13.5, z1: 14.5),
        Rect2(x0: -8.5, x1: -7.5, z0: 2.5, z1: 3.5),    // columns
        Rect2(x0: 7.5, x1: 8.5, z0: 2.5, z1: 3.5),
    ]

    static func isWalkable(_ p: Vec2, radius r: Float = 0.3, doorOpen: (Int) -> Bool) -> Bool {
        for o in lobbyObstacles where o.inset(-r).contains(p) { return false }
        if lobby.inset(r).contains(p) { return true }
        if Rect2(x0: -hallHalfWidth, x1: hallHalfWidth, z0: hallZ0 - 1, z1: hallZ1).inset(r).contains(p) { return true }
        for id in 1...12 {
            let rr = roomRect(id)
            // Keep the player off the stage in front of the screen.
            let walk = id <= 6 ? Rect2(x0: rr.x0 + 1.4, x1: rr.x1, z0: rr.z0, z1: rr.z1) : Rect2(x0: rr.x0, x1: rr.x1 - 1.4, z0: rr.z0, z1: rr.z1)
            if walk.inset(r).contains(p) { return true }
            if doorOpen(id) {
                let z0 = rr.z0 + doorZ0 + r, z1 = rr.z0 + doorZ1 - r
                let strip = id <= 6 ? Rect2(x0: -5.2, x1: -3.0, z0: z0, z1: z1) : Rect2(x0: 3.0, x1: 5.2, z0: z0, z1: z1)
                if strip.contains(p) { return true }
            }
        }
        return false
    }

    // MARK: Lights

    static func buildLights() -> [PointLight] {
        var out: [PointLight] = []
        for x in [-10, 0, 10] as [Float] {
            for z in [5, 14] as [Float] {
                out.append(PointLight(position: Vec3(x, 8.2, z), range: 16, color: Vec3(1.0, 0.86, 0.7), intensity: 26, roomId: nil))
            }
        }
        out.append(PointLight(position: Vec3(-11, 4, 11), range: 8, color: Vec3(1, 0.7, 0.4), intensity: 6, roomId: nil))
        out.append(PointLight(position: Vec3(11, 4, 11), range: 8, color: Vec3(1, 0.85, 0.5), intensity: 6, roomId: nil))
        var z = hallZ0 + 4
        while z < hallZ1 {
            out.append(PointLight(position: Vec3(0, 4.1, z), range: 10, color: Vec3(1, 0.85, 0.7), intensity: 7, roomId: nil))
            z += 9
        }
        for room in CinemaRooms.all {
            let t = transform(room: room.id)
            for k in 0..<4 {
                let lx = 6 + Float(k) * 5.5
                let y = localGround(lx) + 3.2
                out.append(PointLight(position: t.point(Vec3(lx, y, 0.9)), range: 8, color: room.theme.light, intensity: 4.5, roomId: room.id))
                out.append(PointLight(position: t.point(Vec3(lx, y, 13.1)), range: 8, color: room.theme.light, intensity: 4.5, roomId: room.id))
            }
            out.append(PointLight(position: t.point(Vec3(23, 5.5, 7)), range: 12, color: room.theme.light, intensity: 6, roomId: room.id))
        }
        return out
    }

    // MARK: Interaction

    static func nearestInteractable(at p: Vec2, zone: Zone, seatTarget: (room: Int, row: Int, seat: Int)?) -> Interactable? {
        func near(_ q: Vec2, _ d: Float) -> Bool { simd_distance(p, q) < d }
        switch zone {
        case .lobby:
            if near(Vec2(-11, 11), 2.4) { return .boxOffice }
            if near(Vec2(11, 11), 2.4) { return .concession }
            if near(Vec2(-6, 15), 1.6) || near(Vec2(6, 15), 1.6) { return .kiosk }
        case .hall:
            for id in 1...12 where near(doorFront(id), 1.8) { return .door(id) }
        case .room(let id):
            if let t = seatTarget, t.room == id {
                let s = seatPosition(room: id, row: t.row, seat: t.seat)
                if near(Vec2(s.x, s.z), 1.8) { return .seat(room: id, row: t.row, seat: t.seat) }
            }
            if simd_distance(toLocal(p, room: id), Vec2(roomDepth - 1, 7)) < 2.0 { return .door(id) }
        }
        return nil
    }
}
