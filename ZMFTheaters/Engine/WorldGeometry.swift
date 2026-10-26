import simd

/// Procedural construction of every static mesh in the building. Original
/// geometry only — no third-party assets.
enum WorldGeometry {

    // MARK: - Lobby and hall

    static func buildLobbyAndHall(_ b: MeshBuilder) {
        b.xf = .identity
        let L = CinemaWorld.lobby
        let H = CinemaWorld.lobbyCeiling
        let wall = rgb(0.16, 0.1, 0.12)
        let gold = rgb(0.95, 0.72, 0.3)

        // Floors: polished marble in the lobby with a red carpet runner.
        b.flat(x0: L.x0, x1: L.x1, z0: L.z0, z1: L.z1, y: 0, up: true, color: rgb(0.16, 0.13, 0.15), mat: .glossy)
        b.flat(x0: -2.5, x1: 2.5, z0: 0, z1: 20, y: 0.01, up: true, color: rgb(0.45, 0.04, 0.06), mat: .carpet)
        b.flat(x0: L.x0, x1: L.x1, z0: L.z0, z1: L.z1, y: H, up: false, color: rgb(0.08, 0.06, 0.08), mat: .lit(rough: 0.9))

        // Walls
        b.wallX(x: L.x0, z0: 0, z1: 20, y0: 0, y1: H, facingPositive: true, color: wall)
        b.wallX(x: L.x1, z0: 0, z1: 20, y0: 0, y1: H, facingPositive: false, color: wall)
        b.wallZ(z: 0, x0: L.x0, x1: -4, y0: 0, y1: H, facingPositive: true, color: wall)
        b.wallZ(z: 0, x0: 4, x1: L.x1, y0: 0, y1: H, facingPositive: true, color: wall)
        b.wallZ(z: 0, x0: -4, x1: 4, y0: 4, y1: H, facingPositive: true, color: wall)
        // Glass entrance looking out at a night-time street glow.
        b.sign(center: Vec3(0, 2, 0.02), normal: Vec3(0, 0, 1), width: 8, height: 4, color: rgb(0.25, 0.35, 0.6), mat: .glow(1.1))
        b.wallZ(z: 20, x0: L.x0, x1: -4, y0: 0, y1: H, facingPositive: false, color: wall)
        b.wallZ(z: 20, x0: 4, x1: L.x1, y0: 0, y1: H, facingPositive: false, color: wall)
        b.wallZ(z: 20, x0: -4, x1: 4, y0: CinemaWorld.hallCeiling, y1: H, facingPositive: false, color: wall)

        // Gold trim bands and ceiling light panels.
        for z in [0.05, 19.95] as [Float] {
            b.box(Vec3(L.x0, 7.6, z - 0.05), Vec3(L.x1, 7.75, z + 0.05), color: gold, mat: .glow(0.9))
        }
        for x in [-10, 0, 10] as [Float] {
            for z in [5, 14] as [Float] {
                b.box(center: Vec3(x, H - 0.05, z), size: Vec3(3, 0.08, 1.2), color: rgb(1, 0.9, 0.75), mat: .glow(3))
            }
        }

        // Columns
        for x in [-8, 8] as [Float] {
            b.box(Vec3(x - 0.45, 0, 2.55), Vec3(x + 0.45, H, 3.45), color: rgb(0.22, 0.14, 0.12), mat: .lit(rough: 0.4))
            b.box(Vec3(x - 0.5, 0, 2.5), Vec3(x + 0.5, 0.3, 3.5), color: gold, mat: .lit(rough: 0.3, metal: 1))
            b.box(Vec3(x - 0.5, H - 0.4, 2.5), Vec3(x + 0.5, H, 3.5), color: gold, mat: .lit(rough: 0.3, metal: 1))
        }

        // Marquee over the auditorium hall.
        b.sign(center: Vec3(0, 6.4, 19.94), normal: Vec3(0, 0, -1), width: 11, height: 2.4, mat: .glowTex("sign.marquee", 1.6))
        b.sign(center: Vec3(0, 3.9, 19.9), normal: Vec3(0, 0, -1), width: 6, height: 0.7, mat: .glowTex("sign.hall", 1.4))

        // Now Showing light boxes, six either side of the hall entrance.
        for k in 0..<6 {
            let xw = -14.2 + Float(k) * 1.75
            let xe = 5.45 + Float(k) * 1.75
            for (x, room) in [(xw, k + 1), (xe, k + 7)] {
                b.box(center: Vec3(x, 2.6, 19.97), size: Vec3(1.55, 2.3, 0.06), color: gold, mat: .lit(rough: 0.3, metal: 1))
                b.sign(center: Vec3(x, 2.6, 19.9), normal: Vec3(0, 0, -1), width: 1.4, height: 2.1, mat: .glowTex("poster.\(room)", 1.15))
            }
        }

        // Box office (west).
        b.box(Vec3(-14.5, 0, 8.6), Vec3(-7.5, 1.15, 10.4), color: rgb(0.3, 0.06, 0.08), mat: .lit(rough: 0.5))
        b.box(Vec3(-14.6, 1.15, 8.5), Vec3(-7.4, 1.22, 10.5), color: gold, mat: .lit(rough: 0.25, metal: 1))
        b.box(Vec3(-15.9, 0, 6), Vec3(-15.7, 5, 13), color: rgb(0.2, 0.05, 0.06))
        b.sign(center: Vec3(-11, 4.4, 8.4), normal: Vec3(0, 0, -1), width: 5.5, height: 1.0, mat: .glowTex("sign.boxoffice", 1.6))
        for x in [-13, -11, -9] as [Float] {
            b.sign(center: Vec3(x, 1.7, 10.0), normal: Vec3(0, 0, -1), width: 0.8, height: 0.5, color: rgb(0.3, 0.6, 1), mat: .glow(1.2))
        }

        // Concessions (east).
        b.box(Vec3(7.5, 0, 8.6), Vec3(14.5, 1.15, 10.4), color: rgb(0.18, 0.12, 0.08), mat: .lit(rough: 0.5))
        b.sign(center: Vec3(11, 0.6, 8.58), normal: Vec3(0, 0, -1), width: 6.8, height: 0.9, color: rgb(1, 0.75, 0.4), mat: .glow(0.9))
        b.box(Vec3(7.4, 1.15, 8.5), Vec3(14.6, 1.22, 10.5), color: gold, mat: .lit(rough: 0.25, metal: 1))
        b.sign(center: Vec3(11, 4.6, 11.9), normal: Vec3(0, 0, -1), width: 6.5, height: 2.2, mat: .glowTex("sign.menu", 1.3))
        b.sign(center: Vec3(11, 6.1, 8.4), normal: Vec3(0, 0, -1), width: 5.5, height: 1.0, mat: .glowTex("sign.concessions", 1.6))
        // Popcorn machine, soda fountain, slushie machine, candy display.
        b.box(Vec3(8.0, 1.22, 9.0), Vec3(9.2, 2.6, 10.0), color: rgb(1, 0.82, 0.35), mat: .glow(1.4))
        b.box(Vec3(7.95, 2.6, 8.95), Vec3(9.25, 2.75, 10.05), color: rgb(0.8, 0.1, 0.1))
        b.box(Vec3(9.8, 1.22, 9.2), Vec3(11.0, 2.2, 10.0), color: rgb(0.7, 0.7, 0.75), mat: .lit(rough: 0.2, metal: 1))
        for (i, c) in [rgb(0.1, 0.4, 1), rgb(1, 0.2, 0.2), rgb(0.2, 0.9, 0.3)].enumerated() {
            b.box(center: Vec3(10.0 + Float(i) * 0.4, 1.9, 9.18), size: Vec3(0.25, 0.25, 0.05), color: c, mat: .glow(1.5))
        }
        b.box(Vec3(11.6, 1.22, 9.2), Vec3(12.6, 2.3, 10.0), color: rgb(0.3, 0.2, 1.0), mat: .glow(1.0))
        b.box(Vec3(13.0, 1.22, 9.0), Vec3(14.3, 1.9, 10.0), color: rgb(1, 0.4, 0.8), mat: .glow(0.8))
        b.box(Vec3(7.5, 0, 12.0), Vec3(14.5, 3.3, 12.2), color: rgb(0.14, 0.08, 0.06))

        // 4DX preview teaser light box on the west wall.
        b.box(center: Vec3(-15.92, 3.2, 16.6), size: Vec3(0.12, 2.75, 5.4), color: rgb(0.3, 0.9, 1), mat: .glow(1.0))
        b.sign(center: Vec3(-15.84, 3.2, 16.6), normal: Vec3(1, 0, 0), width: 5.0, height: 2.4, mat: .glowTex("sign.4dx", 1.4))

        // Ticket kiosks.
        for x in [-6, 6] as [Float] {
            b.box(Vec3(x - 0.4, 0, 13.6), Vec3(x + 0.4, 1.7, 14.4), color: rgb(0.12, 0.12, 0.14), mat: .lit(rough: 0.3, metal: 0.6))
            b.sign(center: Vec3(x, 1.3, 13.58), normal: Vec3(0, 0, -1), width: 0.6, height: 0.45, mat: .glowTex("sign.kiosk", 1.5))
        }

        buildHall(b)
    }

    static func buildHall(_ b: MeshBuilder) {
        let z0 = CinemaWorld.hallZ0, z1 = CinemaWorld.hallZ1
        let hw = CinemaWorld.hallHalfWidth
        let H = CinemaWorld.hallCeiling
        let wall = rgb(0.12, 0.09, 0.12)
        b.flat(x0: -hw, x1: hw, z0: z0, z1: z1, y: 0, up: true, color: rgb(0.22, 0.05, 0.1), mat: .carpet)
        b.flat(x0: -hw, x1: hw, z0: z0, z1: z1, y: H, up: false, color: rgb(0.07, 0.05, 0.07), mat: .lit(rough: 0.9))
        b.wallZ(z: z1, x0: -hw, x1: hw, y0: 0, y1: H, facingPositive: false, color: wall)

        // Side walls with a door opening for each auditorium.
        for side in [-1, 1] as [Float] {
            let x = side * hw
            let facingPositive = side < 0
            var cursor = z0
            for i in 0..<6 {
                let id = side < 0 ? i + 1 : i + 7
                let base = CinemaWorld.roomBaseZ(id)
                let d0 = base + CinemaWorld.doorZ0, d1 = base + CinemaWorld.doorZ1
                b.wallX(x: x, z0: cursor, z1: d0, y0: 0, y1: H, facingPositive: facingPositive, color: wall)
                b.wallX(x: x, z0: d0, z1: d1, y0: CinemaWorld.doorHeight, y1: H, facingPositive: facingPositive, color: wall)
                cursor = d1
                let room = CinemaRooms.room(id)
                let accent = rgb(room.theme.accent)
                // Glowing door frame in the room's accent colour.
                b.box(Vec3(x - 0.12, 0, d0 - 0.15), Vec3(x + 0.12, CinemaWorld.doorHeight + 0.15, d0), color: accent, mat: .glow(1.3))
                b.box(Vec3(x - 0.12, 0, d1), Vec3(x + 0.12, CinemaWorld.doorHeight + 0.15, d1 + 0.15), color: accent, mat: .glow(1.3))
                b.box(Vec3(x - 0.12, CinemaWorld.doorHeight, d0 - 0.15), Vec3(x + 0.12, CinemaWorld.doorHeight + 0.15, d1 + 0.15), color: accent, mat: .glow(1.3))
                // Jambs bridging the hall wall to the auditorium back wall.
                let inner = side * (hw + 0.25)
                b.box(Vec3(min(x, inner), 0, d0 - 0.05), Vec3(max(x, inner), CinemaWorld.doorHeight, d0), color: wall)
                b.box(Vec3(min(x, inner), 0, d1), Vec3(max(x, inner), CinemaWorld.doorHeight, d1 + 0.05), color: wall)
                b.box(Vec3(min(x, inner), CinemaWorld.doorHeight - 0.02, d0), Vec3(max(x, inner), CinemaWorld.doorHeight, d1), color: wall)
                // Room sign above the door and a poster light box beside it.
                let n = Vec3(-side, 0, 0)
                b.sign(center: Vec3(x - side * 0.03, 3.5, (d0 + d1) / 2), normal: n, width: 2.8, height: 0.95, mat: .glowTex("door.\(id)", 1.5))
                b.sign(center: Vec3(x - side * 0.03, 1.6, base + 3.4), normal: n, width: 1.3, height: 1.95, mat: .glowTex("poster.\(id)", 1.15))
                b.box(center: Vec3(x, 1.6, base + 3.4), size: Vec3(0.05, 2.15, 1.5), color: accent, mat: .glow(0.6))
            }
            b.wallX(x: x, z0: cursor, z1: z1, y0: 0, y1: H, facingPositive: facingPositive, color: wall)
        }
        var z = z0 + 4
        while z < z1 {
            b.box(center: Vec3(0, H - 0.04, z), size: Vec3(2.2, 0.06, 0.8), color: rgb(1, 0.88, 0.7), mat: .glow(2.5))
            z += 9
        }
        // Floor guide lights along the hall edges.
        b.box(Vec3(-hw + 0.05, 0.02, z0), Vec3(-hw + 0.12, 0.06, z1), color: rgb(1, 0.6, 0.2), mat: .glow(1.5))
        b.box(Vec3(hw - 0.12, 0.02, z0), Vec3(hw - 0.05, 0.06, z1), color: rgb(1, 0.6, 0.2), mat: .glow(1.5))
    }

    // MARK: - Auditoriums

    static func buildRoom(_ room: CinemaRoom, _ b: MeshBuilder) {
        b.xf = CinemaWorld.transform(room: room.id)
        let t = room.theme
        let D = CinemaWorld.roomDepth, W = CinemaWorld.roomWidth
        let yMin = CinemaWorld.roomFloorMin, yMax = CinemaWorld.roomCeiling
        let wall = rgb(t.wall)
        let carpet = rgb(t.carpet)

        // Stadium floor: front well, eight risers, rear cross-aisle at hall level.
        b.flat(x0: 0, x1: 7.2, z0: 0, z1: W, y: yMin, up: true, color: carpet, mat: .carpet)
        var prev = yMin
        for r in 0..<8 {
            let x0 = 7.2 + Float(r) * 1.6, x1 = x0 + 1.6
            let h = CinemaWorld.rowFloor(r)
            b.flat(x0: x0, x1: x1, z0: 0, z1: W, y: h, up: true, color: carpet, mat: .carpet)
            b.wallX(x: x0, z0: 0, z1: W, y0: prev, y1: h, facingPositive: false, color: rgb(t.carpet, 0.7))
            // LED step lights in both aisles.
            for (za, zb) in [(Float(0.3), Float(1.6)), (W - 1.6, W - 0.3)] {
                b.box(Vec3(x0 - 0.02, h - 0.06, za), Vec3(x0 + 0.02, h - 0.02, zb), color: rgb(t.light), mat: .glow(2))
            }
            prev = h
        }
        b.flat(x0: 20, x1: D, z0: 0, z1: W, y: 0, up: true, color: carpet, mat: .carpet)

        // Shell
        b.wallZ(z: 0, x0: 0, x1: D, y0: yMin, y1: yMax, facingPositive: true, color: wall)
        b.wallZ(z: W, x0: 0, x1: D, y0: yMin, y1: yMax, facingPositive: false, color: wall)
        b.wallX(x: 0, z0: 0, z1: W, y0: yMin, y1: yMax, facingPositive: true, color: rgb(0.02, 0.02, 0.02))
        b.wallX(x: D, z0: 0, z1: CinemaWorld.doorZ0, y0: 0, y1: yMax, facingPositive: false, color: wall)
        b.wallX(x: D, z0: CinemaWorld.doorZ1, z1: W, y0: 0, y1: yMax, facingPositive: false, color: wall)
        b.wallX(x: D, z0: CinemaWorld.doorZ0, z1: CinemaWorld.doorZ1, y0: CinemaWorld.doorHeight, y1: yMax, facingPositive: false, color: wall)
        b.flat(x0: 0, x1: D, z0: 0, z1: W, y: yMax, up: false, color: rgb(t.wall, 0.5), mat: .lit(rough: 0.95))

        // Stage, screen frame, masking curtains, screen.
        b.box(Vec3(0, yMin, 0), Vec3(1.2, yMin + 0.5, W), color: rgb(0.05, 0.05, 0.05))
        b.box(Vec3(0.05, -1.75, 0.6), Vec3(0.3, 4.15, W - 0.6), color: rgb(0.01, 0.01, 0.01))
        b.box(Vec3(0.3, yMin, 0.1), Vec3(0.8, 5.0, 0.95), color: rgb(t.accent, 0.35), mat: .lit(rough: 1))
        b.box(Vec3(0.3, yMin, W - 0.95), Vec3(0.8, 5.0, W - 0.1), color: rgb(t.accent, 0.35), mat: .lit(rough: 1))
        curvedScreen(room, b)

        // Wall sconces (match the light list in CinemaWorld.buildLights).
        for k in 0..<4 {
            let lx = 6 + Float(k) * 5.5
            let y = CinemaWorld.localGround(lx) + 3.2
            b.box(center: Vec3(lx, y, 0.12), size: Vec3(0.5, 0.7, 0.2), color: rgb(t.light), mat: .glow(2.2))
            b.box(center: Vec3(lx, y, W - 0.12), size: Vec3(0.5, 0.7, 0.2), color: rgb(t.light), mat: .glow(2.2))
        }

        // Exit sign and projection-booth window.
        b.box(center: Vec3(D - 0.1, 2.95, 7), size: Vec3(0.1, 0.3, 0.9), color: rgb(0.1, 1, 0.3), mat: .glow(2))
        // Projection booth: port window and the projector lens the beam comes from.
        b.sign(center: Vec3(D - 0.02, 5.4, 7), normal: Vec3(-1, 0, 0), width: 1.2, height: 0.7, color: rgb(0.08, 0.09, 0.12), mat: .lit(rough: 0.15, metal: 0.2))
        b.box(center: Vec3(D - 0.06, 5.4, 7), size: Vec3(0.12, 0.22, 0.22), color: rgb(0.9, 0.95, 1), mat: .glow(3))
        // Acoustic wall panels for texture and depth.
        var px: Float = 2.5
        while px < D - 2 {
            let g = CinemaWorld.localGround(px)
            b.box(Vec3(px, g + 1.6, 0.0), Vec3(px + 1.8, yMax - 1.6, 0.06), color: rgb(t.wall, 0.75), mat: .lit(rough: 1))
            b.box(Vec3(px, g + 1.6, W - 0.06), Vec3(px + 1.8, yMax - 1.6, W), color: rgb(t.wall, 0.75), mat: .lit(rough: 1))
            px += 2.4
        }

        // Row letters on both side walls.
        for r in 0..<8 {
            let y = CinemaWorld.rowFloor(r) + 1.3
            b.sign(center: Vec3(CinemaWorld.rowX(r), y, 0.02), normal: Vec3(0, 0, 1), width: 0.45, height: 0.45, mat: .glowTex("row.\(r)", 1.2))
            b.sign(center: Vec3(CinemaWorld.rowX(r), y, W - 0.02), normal: Vec3(0, 0, -1), width: 0.45, height: 0.45, mat: .glowTex("row.\(r)", 1.2))
        }

        // Visible but virtual premium 4DX environmental equipment.
        // Capped to simple batched meshes to keep decoding the film first.
        for side in [Float(0.24), W - 0.24] {
            for p in [Float(6), 11, 16, 21] {
                let floor = CinemaWorld.localGround(p)
                b.box(center: Vec3(p, floor + 2.1, side), size: Vec3(0.48, 0.3, 0.2),
                      color: rgb(0.075, 0.085, 0.1), mat: .lit(rough: 0.42, metal: 0.7))
                b.box(center: Vec3(p, floor + 2.1, side), size: Vec3(0.14, 0.14, 0.27),
                      color: rgb(0.23, 0.28, 0.34), mat: .lit(rough: 0.28, metal: 0.75))
            }
        }
        buildSeats(room, b)
        decorate(room, b)
        b.xf = .identity
    }

    static func buildSeats(_ room: CinemaRoom, _ b: MeshBuilder) {
        let t = room.theme
        let seatColor = rgb(t.seat)
        let frame = rgb(0.06, 0.06, 0.07)
        for r in 0..<8 {
            let x = CinemaWorld.rowX(r)
            let fl = CinemaWorld.rowFloor(r)
            let vip = Seating.vipRows.contains(r)
            for s in 0..<8 {
                let z = CinemaWorld.seatZ(s)
                let col = vip ? rgb(t.seat, 1.35) : seatColor
                // Reclining premium seat: base, cushion, backrest, armrests.
                b.box(Vec3(x - 0.4, fl, z - 0.42), Vec3(x + 0.35, fl + 0.3, z + 0.42), color: frame)
                b.box(Vec3(x - 0.42, fl + 0.3, z - 0.42), Vec3(x + 0.35, fl + 0.52, z + 0.42), color: col, mat: .lit(rough: 0.8))
                b.box(Vec3(x + 0.3, fl + 0.4, z - 0.42), Vec3(x + 0.52, fl + 1.2, z + 0.42), color: col, mat: .lit(rough: 0.8))
                b.box(Vec3(x - 0.35, fl + 0.3, z - 0.52), Vec3(x + 0.45, fl + 0.75, z - 0.42), color: frame, mat: .lit(rough: 0.4))
                // Virtual motion platform: four supports, rails, actuator
                // shrouds and mounting hardware under each premium chair.
                let chassis = rgb(0.13, 0.17, 0.2)
                let metal = MaterialKey.lit(rough: 0.35, metal: 0.75)
                for dx in [-0.27, 0.26] as [Float] {
                    for dz in [-0.26, 0.26] as [Float] {
                        b.box(center: Vec3(x + dx, fl + 0.13, z + dz),
                              size: Vec3(0.055, 0.26, 0.055), color: rgb(0.48, 0.52, 0.56), mat: metal)
                    }
                }
                b.box(center: Vec3(x - 0.05, fl + 0.08, z),
                      size: Vec3(0.65, 0.09, 0.76), color: chassis, mat: metal)
                b.box(center: Vec3(x - 0.05, fl + 0.26, z),
                      size: Vec3(0.61, 0.07, 0.69), color: chassis, mat: metal)
                b.box(center: Vec3(x - 0.38, fl + 0.43, z - 0.49),
                      size: Vec3(0.08, 0.1, 0.1), color: rgb(0.58, 0.62, 0.67), mat: metal)
                // Headrest pillow, lit cupholder and a little LED under the seat.
                b.box(Vec3(x + 0.28, fl + 1.0, z - 0.3), Vec3(x + 0.46, fl + 1.24, z + 0.3), color: rgb(t.seat, vip ? 1.0 : 0.75), mat: .lit(rough: 0.9))
                b.box(center: Vec3(x - 0.22, fl + 0.757, z - 0.47), size: Vec3(0.1, 0.012, 0.1), color: rgb(t.accent), mat: .glow(1.6))
                b.box(center: Vec3(x - 0.38, fl + 0.06, z), size: Vec3(0.04, 0.02, 0.6), color: rgb(t.light), mat: .glow(1.2))
                // Seat number plaque on the back, readable from the row behind.
                b.sign(center: Vec3(x + 0.53, fl + 1.08, z), normal: Vec3(1, 0, 0), width: 0.15, height: 0.11, mat: .glowTex("num.\(s)", 0.55))
            }
            let zEnd = CinemaWorld.seatZ(7) + 0.52
            b.box(Vec3(x - 0.35, fl + 0.3, zEnd - 0.1), Vec3(x + 0.45, fl + 0.75, zEnd), color: frame, mat: .lit(rough: 0.4))
        }
    }

    /// A gently curved screen (edges toward the audience), built from strips so
    /// the projected image wraps naturally. Texture u runs left→right as seen
    /// from the seats in both wings.
    static func curvedScreen(_ room: CinemaRoom, _ b: MeshBuilder) {
        let segments = 24
        let halfW = CinemaWorld.screenSize.x / 2, halfH = CinemaWorld.screenSize.y / 2
        let sag: Float = 0.35
        let y0: Float = 1.2 - halfH, y1: Float = 1.2 + halfH
        let mat = MaterialKey.screen("screen.\(room.id)")
        let flip = room.id <= 6   // west wing: viewer's right is −z
        for i in 0..<segments {
            let t0 = -1 + 2 * Float(i) / Float(segments)
            let t1 = -1 + 2 * Float(i + 1) / Float(segments)
            let z0 = 7 + t0 * halfW, z1 = 7 + t1 * halfW
            let x0 = 0.35 + sag * t0 * t0, x1 = 0.35 + sag * t1 * t1
            let tm = (t0 + t1) / 2
            let n = simd_normalize(Vec3(1, 0, -(2 * sag * tm) / halfW))
            var u0 = (t0 + 1) / 2, u1 = (t1 + 1) / 2
            if flip { u0 = 1 - u0; u1 = 1 - u1 }
            b.quad(Vec3(x0, y0, z0), Vec3(x1, y0, z1), Vec3(x1, y1, z1), Vec3(x0, y1, z0), normal: n, color: Vec4(1, 1, 1, 1), mat: mat,
                   uv: (Vec2(u0, 1), Vec2(u1, 1), Vec2(u1, 0), Vec2(u0, 0)))
        }
    }

    /// Light volume from the booth lens to the four screen corners. Drawn
    /// additively only while a screening is running in that room.
    static func projectorBeam(_ room: CinemaRoom, _ b: MeshBuilder) {
        b.xf = CinemaWorld.transform(room: room.id)
        let apex = Vec3(CinemaWorld.roomDepth - 0.12, 5.4, 7)
        let halfW = CinemaWorld.screenSize.x / 2 - 0.1, halfH = CinemaWorld.screenSize.y / 2 - 0.05
        let c = [Vec3(0.5, 1.2 - halfH, 7 - halfW), Vec3(0.5, 1.2 - halfH, 7 + halfW), Vec3(0.5, 1.2 + halfH, 7 + halfW), Vec3(0.5, 1.2 + halfH, 7 - halfW)]
        let mat = MaterialKey(mode: 7, texture: nil, roughness: 1, metallic: 0, emissive: 1)
        for i in 0..<4 {
            b.triangle(apex, c[i], c[(i + 1) % 4], uvs: (Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)), color: Vec4(1, 1, 1, 1), mat: mat)
        }
        b.xf = .identity
    }

    // MARK: - Themed decoration

    static func decorate(_ room: CinemaRoom, _ b: MeshBuilder) {
        let t = room.theme
        let D = CinemaWorld.roomDepth, W = CinemaWorld.roomWidth
        let yMin = CinemaWorld.roomFloorMin, yMax = CinemaWorld.roomCeiling
        let accent = rgb(t.accent)
        var rng = SeededRNG(seed: UInt64(room.id) * 7919)
        func rand() -> Float { Float(rng.next() % 10_000) / 10_000 }

        func alongWalls(step: Float, _ body: (Float) -> Void) {
            var x: Float = 3
            while x < D - 2 { body(x); x += step }
        }

        switch t.decor {
        case .palace:
            alongWalls(step: 4) { x in
                let g = CinemaWorld.localGround(x)
                b.box(Vec3(x - 0.3, g, 0), Vec3(x + 0.3, yMax, 0.35), color: accent, mat: .lit(rough: 0.3, metal: 1))
                b.box(Vec3(x - 0.3, g, W - 0.35), Vec3(x + 0.3, yMax, W), color: accent, mat: .lit(rough: 0.3, metal: 1))
            }
            b.box(Vec3(0.2, 4.3, 0), Vec3(0.9, 5.4, W), color: accent, mat: .lit(rough: 0.3, metal: 1))
            b.box(Vec3(0.25, 5.4, 0.5), Vec3(0.85, 5.8, W - 0.5), color: rgb(0.5, 0.05, 0.06))
        case .industrial:
            var x: Float = 2
            while x < D { b.box(Vec3(x - 0.15, yMax - 0.5, 0), Vec3(x + 0.15, yMax, W), color: rgb(0.2, 0.2, 0.22), mat: .lit(rough: 0.35, metal: 1)); x += 3 }
            b.box(Vec3(1, 0.9, 0.02), Vec3(D - 1, 1.0, 0.08), color: accent, mat: .glow(2))
            b.box(Vec3(1, 0.9, W - 0.08), Vec3(D - 1, 1.0, W - 0.02), color: accent, mat: .glow(2))
        case .expedition:
            var x: Float = 2
            while x < D { b.box(Vec3(x - 0.2, yMax - 0.4, 0), Vec3(x + 0.2, yMax, W), color: rgb(0.3, 0.18, 0.08), mat: .lit(rough: 0.9)); x += 3.5 }
            alongWalls(step: 6) { x in
                let g = CinemaWorld.localGround(x)
                b.box(Vec3(x - 0.5, g, 0), Vec3(x + 0.5, yMax, 0.6), color: rgb(0.2, 0.32, 0.15), mat: .lit(rough: 1))
                b.box(Vec3(x - 0.5, g, W - 0.6), Vec3(x + 0.5, yMax, W), color: rgb(0.2, 0.32, 0.15), mat: .lit(rough: 1))
            }
        case .lounge:
            alongWalls(step: 2) { x in
                let g = CinemaWorld.localGround(x)
                b.box(Vec3(x - 0.6, g + 0.5, 0), Vec3(x + 0.6, yMax - 0.8, 0.12), color: rgb(t.wall, 1.6), mat: .lit(rough: 1))
                b.box(Vec3(x - 0.6, g + 0.5, W - 0.12), Vec3(x + 0.6, yMax - 0.8, W), color: rgb(t.wall, 1.6), mat: .lit(rough: 1))
            }
            b.box(Vec3(0, yMax - 0.15, 0.02), Vec3(D, yMax - 0.05, 0.1), color: accent, mat: .glow(2.2))
            b.box(Vec3(0, yMax - 0.15, W - 0.1), Vec3(D, yMax - 0.05, W - 0.02), color: accent, mat: .glow(2.2))
        case .gothic:
            alongWalls(step: 4.5) { x in
                let g = CinemaWorld.localGround(x)
                for (i, w) in [Float(0.8), 0.6, 0.4, 0.2].enumerated() {
                    let y0 = g + Float(i) * 2.0, y1 = y0 + 2.0
                    b.box(Vec3(x - w / 2, y0, 0), Vec3(x + w / 2, y1, 0.4), color: rgb(0.12, 0.1, 0.1), mat: .lit(rough: 1))
                    b.box(Vec3(x - w / 2, y0, W - 0.4), Vec3(x + w / 2, y1, W), color: rgb(0.12, 0.1, 0.1), mat: .lit(rough: 1))
                }
                b.box(center: Vec3(x, g + 1.4, 0.5), size: Vec3(0.08, 0.25, 0.08), color: rgb(1, 0.5, 0.2), mat: .glow(3))
                b.box(center: Vec3(x, g + 1.4, W - 0.5), size: Vec3(0.08, 0.25, 0.08), color: rgb(1, 0.5, 0.2), mat: .glow(3))
            }
        case .comedy:
            let palette = [rgb(1, 0.85, 0.2), rgb(0.95, 0.25, 0.3), rgb(0.2, 0.6, 1), rgb(0.3, 0.85, 0.4)]
            var i = 0
            var x: Float = 1
            while x < D - 1 {
                let g = CinemaWorld.localGround(x)
                b.box(Vec3(x, g + 0.4, 0), Vec3(x + 1.2, yMax - 1, 0.06), color: palette[i % 4], mat: .lit(rough: 0.6))
                b.box(Vec3(x, g + 0.4, W - 0.06), Vec3(x + 1.2, yMax - 1, W), color: palette[(i + 2) % 4], mat: .lit(rough: 0.6))
                x += 1.6; i += 1
            }
            var z: Float = 0.6
            while z < W - 0.5 { b.box(center: Vec3(0.6, 5.6, z), size: Vec3(0.15, 0.15, 0.15), color: rgb(1, 0.9, 0.6), mat: .glow(3)); z += 0.6 }
        case .hero:
            for (y, c) in [(Float(1.2), rgb(0.9, 0.1, 0.15)), (Float(4.6), rgb(0.2, 0.45, 1))] {
                b.box(Vec3(0.5, y, 0.02), Vec3(D - 0.5, y + 0.12, 0.1), color: c, mat: .glow(2.5))
                b.box(Vec3(0.5, y, W - 0.1), Vec3(D - 0.5, y + 0.12, W - 0.02), color: c, mat: .glow(2.5))
            }
            b.box(Vec3(0.2, 4.4, 1), Vec3(0.5, 4.55, W - 1), color: rgb(0.95, 0.75, 0.3), mat: .glow(2))
        case .enchanted:
            alongWalls(step: 3.2) { x in
                let g = CinemaWorld.localGround(x)
                let h = 2 + rand() * 3
                let c = Int(x) % 2 == 0 ? rgb(0.3, 0.95, 0.65) : rgb(0.65, 0.4, 1)
                b.box(Vec3(x - 0.18, g, 0.2), Vec3(x + 0.18, g + h, 0.56), color: c, mat: .glow(1.6))
                b.box(Vec3(x - 0.18, g, W - 0.56), Vec3(x + 0.18, g + h * 0.8, W - 0.2), color: c, mat: .glow(1.6))
            }
        case .galaxy:
            var x: Float = 1
            while x < D { b.box(Vec3(x, yMin, 0.02), Vec3(x + 0.05, yMax, 0.07), color: accent, mat: .glow(1.8)); b.box(Vec3(x, yMin, W - 0.07), Vec3(x + 0.05, yMax, W - 0.02), color: accent, mat: .glow(1.8)); x += 2.5 }
            for y in [Float(0.5), 3.0, 5.5] {
                b.box(Vec3(0, y, 0.02), Vec3(D, y + 0.05, 0.07), color: accent, mat: .glow(1.8))
                b.box(Vec3(0, y, W - 0.07), Vec3(D, y + 0.05, W - 0.02), color: accent, mat: .glow(1.8))
            }
            for _ in 0..<160 {
                b.box(center: Vec3(rand() * D, yMax - 0.02, rand() * W), size: Vec3(0.05, 0.02, 0.05), color: rgb(0.8, 0.9, 1), mat: .glow(4))
            }
        case .toybox:
            let palette = [rgb(1, 0.35, 0.35), rgb(1, 0.75, 0.2), rgb(0.35, 0.8, 0.4), rgb(0.3, 0.6, 1), rgb(0.75, 0.45, 1)]
            alongWalls(step: 1.7) { x in
                let g = CinemaWorld.localGround(x)
                let s = 0.6 + rand() * 0.7
                let y = g + 0.8 + rand() * 3.5
                b.box(Vec3(x, y, 0), Vec3(x + s, y + s, s * 0.6), color: palette[Int(rand() * 5) % 5], mat: .lit(rough: 0.5))
                b.box(Vec3(x, y, W - s * 0.6), Vec3(x + s, y + s, W), color: palette[Int(rand() * 5) % 5], mat: .lit(rough: 0.5))
            }
        case .noir:
            alongWalls(step: 1.4) { x in
                let g = CinemaWorld.localGround(x)
                b.box(Vec3(x, g + 0.3, 0.02), Vec3(x + 0.06, yMax - 0.5, 0.08), color: accent, mat: .lit(rough: 0.25, metal: 1))
                b.box(Vec3(x, g + 0.3, W - 0.08), Vec3(x + 0.06, yMax - 0.5, W - 0.02), color: accent, mat: .lit(rough: 0.25, metal: 1))
            }
        case .premiere:
            b.box(Vec3(0.2, 4.3, 0), Vec3(0.9, 5.6, W), color: accent, mat: .lit(rough: 0.25, metal: 1))
            alongWalls(step: 5) { x in
                b.box(center: Vec3(x, yMax - 0.3, 0.4), size: Vec3(0.4, 0.4, 0.4), color: rgb(1, 0.95, 0.8), mat: .glow(3.5))
                b.box(center: Vec3(x, yMax - 0.3, W - 0.4), size: Vec3(0.4, 0.4, 0.4), color: rgb(1, 0.95, 0.8), mat: .glow(3.5))
            }
            for _ in 0..<120 {
                b.box(center: Vec3(rand() * D, yMax - 0.02, rand() * W), size: Vec3(0.06, 0.02, 0.06), color: rgb(1, 0.85, 0.5), mat: .glow(4))
            }
            b.flat(x0: 20, x1: D, z0: 5.5, z1: 8.5, y: 0.012, up: true, color: rgb(0.6, 0.03, 0.05), mat: .carpet)
        }
    }

    // MARK: - Dynamic helper meshes

    /// Unit cube centred at the origin, used for dynamic objects (doors, avatar, seat marker).
    static func unitCube() -> [Vertex] {
        let b = MeshBuilder()
        b.box(center: .zero, size: Vec3(1, 1, 1), color: Vec4(1, 1, 1, 1), mat: .lit())
        return b.batches.values.first ?? []
    }
}
