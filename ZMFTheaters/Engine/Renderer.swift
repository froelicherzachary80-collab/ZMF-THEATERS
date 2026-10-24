import UIKit
import Metal
import MetalKit
import CoreVideo
import simd

/// Swift mirror of `FrameUniforms` in Shaders.metal.
struct FrameUniforms {
    var viewProj: simd_float4x4
    var cameraPos: Vec4
    var ambient: Vec4
    var fog: Vec4
    var screenCenter: Vec4
    var screenNormal: Vec4
    var screenRight: Vec4
    var screenUp: Vec4
    var lightInfo: Vec4
}

/// Swift mirror of `DrawUniforms` in Shaders.metal.
struct DrawUniforms {
    var model: simd_float4x4
    var baseColor: Vec4
    var emissive: Vec4
    var params: Vec4
}

private struct Batch {
    var key: MaterialKey
    var buffer: MTLBuffer
    var count: Int
}

/// ZMF Cinema Engine renderer. Static geometry is batched per zone (lobby/hall
/// and each auditorium) and only zones the player can see are drawn. Only the
/// auditorium hosting the current screening decodes and displays video.
@MainActor
final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let averagePipeline: MTLComputePipelineState
    private let depthState: MTLDepthStencilState
    private var depthTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    private let inflight = DispatchSemaphore(value: 3)
    let factory: TextureFactory

    private var lobbyBatches: [Batch] = []
    private var roomBatches: [Int: [Batch]] = [:]
    private let cube: MTLBuffer
    private let cubeCount: Int
    private let lights = CinemaWorld.buildLights()
    private let screenAverage: MTLBuffer

    private var textures: [String: MTLTexture] = [:]
    private let white: MTLTexture
    private let black: MTLTexture
    private var videoTexture: MTLTexture?
    private var retainedCV: [CVMetalTexture] = []
    private var slideTexture: MTLTexture?
    private var slideVersion = -1
    private var identTexture: MTLTexture?
    private var identTimer: Double = 0
    private var lastScreenEngineId: ObjectIdentifier?

    private(set) var houseLights: Float = 1
    private var lastTimestamp: CFTimeInterval = 0

    weak var game: CinemaGame?
    weak var session: TheaterSession?
    var settings = AppSettings()
    var thermalThrottle = false

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        let factory = TextureFactory(device: device)
        self.factory = factory

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2; vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0
        vd.attributes[3].format = .float4; vd.attributes[3].offset = 32; vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride

        let pd = MTLRenderPipelineDescriptor()
        pd.label = "ZMF Cinema Forward"
        pd.vertexFunction = library.makeFunction(name: "cinema_vertex")
        pd.fragmentFunction = library.makeFunction(name: "cinema_fragment")
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pd.depthAttachmentPixelFormat = .depth32Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd),
              let avgFn = library.makeFunction(name: "screen_average"),
              let avg = try? device.makeComputePipelineState(function: avgFn) else { return nil }
        self.pipeline = pipeline
        self.averagePipeline = avg

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds

        let cubeVerts = WorldGeometry.unitCube()
        guard let cb = device.makeBuffer(bytes: cubeVerts, length: cubeVerts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared),
              let avgBuf = device.makeBuffer(length: MemoryLayout<Vec4>.stride, options: .storageModeShared),
              let w = factory.solid(Vec4(1, 1, 1, 1)),
              let b = factory.solid(Vec4(0, 0, 0, 1)) else { return nil }
        cube = cb
        cubeCount = cubeVerts.count
        screenAverage = avgBuf
        white = w
        black = b
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        buildStaticGeometry()
        buildStaticTextures()
    }

    // MARK: Setup

    private func upload(_ builder: MeshBuilder) -> [Batch] {
        builder.batches.compactMap { key, verts in
            guard !verts.isEmpty,
                  let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared) else { return nil }
            return Batch(key: key, buffer: buf, count: verts.count)
        }
    }

    private func buildStaticGeometry() {
        let lobby = MeshBuilder()
        WorldGeometry.buildLobbyAndHall(lobby)
        lobbyBatches = upload(lobby)
        for room in CinemaRooms.all {
            let b = MeshBuilder()
            WorldGeometry.buildRoom(room, b)
            roomBatches[room.id] = upload(b)
        }
    }

    private func buildStaticTextures() {
        let gold = UIColor(red: 1, green: 0.8, blue: 0.35, alpha: 1)
        let dark = UIColor(red: 0.08, green: 0.02, blue: 0.04, alpha: 1)
        textures["sign.marquee"] = factory.marquee()
        textures["sign.boxoffice"] = factory.label("BOX OFFICE", size: CGSize(width: 900, height: 160), font: .systemFont(ofSize: 110, weight: .black), fg: gold, bg: dark, border: gold)
        textures["sign.concessions"] = factory.label("CONCESSIONS", size: CGSize(width: 900, height: 160), font: .systemFont(ofSize: 104, weight: .black), fg: gold, bg: dark, border: gold)
        textures["sign.hall"] = factory.label("AUDITORIUMS 01–12  →", size: CGSize(width: 900, height: 110), font: .systemFont(ofSize: 70, weight: .heavy), fg: .white, bg: dark)
        textures["sign.kiosk"] = factory.label("TICKETS", size: CGSize(width: 256, height: 190), font: .systemFont(ofSize: 56, weight: .black), fg: .white, bg: UIColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        for r in 0..<8 {
            textures["row.\(r)"] = factory.label(Seating.rowLetter(r), size: CGSize(width: 128, height: 128), font: .systemFont(ofSize: 96, weight: .black), fg: gold, bg: dark, border: gold)
            textures["num.\(r)"] = factory.label("\(r + 1)", size: CGSize(width: 128, height: 92), font: .systemFont(ofSize: 70, weight: .bold), fg: .white, bg: UIColor(white: 0.08, alpha: 1))
        }
        textures["sign.menu"] = factory.menuBoard(settings)
    }

    func setTexture(_ key: String, _ texture: MTLTexture?) {
        textures[key] = texture
    }

    // MARK: Frame

    func draw(layer: CAMetalLayer, timestamp: CFTimeInterval) {
        let dt = lastTimestamp == 0 ? Float(1.0 / 60.0) : Float(min(0.1, timestamp - lastTimestamp))
        lastTimestamp = timestamp
        guard let game, let session else { return }
        game.update(dt: dt)

        // House lights fade slowly like a real auditorium dimmer.
        houseLights += (session.targetLights - houseLights) * min(1, dt * 0.45)

        updateScreenContent(session: session, dt: Double(dt))

        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        if depthTexture == nil || depthTexture!.width != Int(size.width) || depthTexture!.height != Int(size.height) {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .memoryless
            depthTexture = device.makeTexture(descriptor: d)
        }

        inflight.wait()
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }

        let activeRoom = session.roomId
        let activeScreen = activeScreenTexture(session: session)

        // Screen glow: average the image currently on the active screen.
        if let tex = activeScreen, let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(averagePipeline)
            enc.setTexture(tex, index: 0)
            enc.setBuffer(screenAverage, offset: 0, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
        }

        let cam = game.camera()
        let aspect = Float(size.width / size.height)
        let proj = Mat4.perspective(fovyRadians: game.isSeated ? 0.95 : 1.1, aspect: aspect, near: 0.05, far: 160)
        let view = Mat4.lookAt(eye: cam.eye, target: cam.target, up: Vec3(0, 1, 0))

        // Visibility: lobby/hall always; an auditorium when inside it or when its door is open nearby.
        let zone = game.zone
        var visibleRooms: [Int] = []
        if case .room(let id) = zone { visibleRooms = [id] }
        for id in 1...12 where !visibleRooms.contains(id) && game.doorOpen[id] > 0.02 {
            let d = simd_distance(Vec2(cam.eye.x, cam.eye.z), CinemaWorld.doorFront(id))
            if d < 14 { visibleRooms.append(id) }
        }

        var frame = FrameUniforms(
            viewProj: proj * view,
            cameraPos: Vec4(cam.eye.x, cam.eye.y, cam.eye.z, game.time),
            ambient: Vec4(0.05, 0.045, 0.05, 0),
            fog: Vec4(0.02, 0.015, 0.02, settings.fogEnabled ? 0.006 : 0),
            screenCenter: .zero, screenNormal: .zero, screenRight: .zero, screenUp: .zero,
            lightInfo: Vec4(0, 1.0, 0, 0)
        )
        if case .room(let id) = zone {
            let room = CinemaRooms.room(id)
            let dim: Float = (id == activeRoom) ? houseLights : 1
            frame.ambient = Vec4(room.theme.light.x, room.theme.light.y, room.theme.light.z, 0) * (0.012 + 0.05 * dim)
            frame.fog = Vec4(room.theme.wall.x * 0.15, room.theme.wall.y * 0.15, room.theme.wall.z * 0.15, settings.fogEnabled ? room.theme.fog * (1.3 - dim * 0.5) : 0)
        }
        if let id = activeRoom, activeScreen != nil, visibleRooms.contains(id) {
            let c = CinemaWorld.screenCenter(id), n = CinemaWorld.screenNormal(id)
            let right = simd_normalize(simd_cross(-n, Vec3(0, 1, 0)))
            frame.screenCenter = Vec4(c.x, c.y, c.z, 1)
            frame.screenNormal = Vec4(n.x, n.y, n.z, Float(settings.screenBrightness))
            frame.screenRight = Vec4(right.x, right.y, right.z, CinemaWorld.screenSize.x / 2)
            frame.screenUp = Vec4(0, 1, 0, CinemaWorld.screenSize.y / 2)
        }

        // Pick the 16 most relevant lights near the camera.
        var candidates: [(Float, Vec4, Vec4)] = []
        for l in lights {
            if let r = l.roomId, !visibleRooms.contains(r) { continue }
            let d = simd_distance(l.position, cam.eye)
            if d > l.range + 25 { continue }
            var intensity = l.intensity
            if let r = l.roomId, r == activeRoom { intensity *= max(0.02, houseLights) }
            candidates.append((d, Vec4(l.position.x, l.position.y, l.position.z, l.range), Vec4(l.color.x, l.color.y, l.color.z, intensity)))
        }
        candidates.sort { $0.0 < $1.0 }
        var lightData: [Vec4] = []
        for c in candidates.prefix(16) { lightData.append(c.1); lightData.append(c.2) }
        frame.lightInfo.x = Float(lightData.count / 2)
        if lightData.isEmpty { lightData = [.zero, .zero] }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            cmd.commit()
            return
        }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        enc.setFragmentBuffer(screenAverage, offset: 0, index: 3)
        lightData.withUnsafeBytes { raw in
            enc.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 4)
        }

        drawBatches(lobbyBatches, enc: enc, roomId: nil, activeRoom: activeRoom, activeScreen: activeScreen)
        for id in visibleRooms {
            drawBatches(roomBatches[id] ?? [], enc: enc, roomId: id, activeRoom: activeRoom, activeScreen: activeScreen)
        }
        drawDynamic(enc: enc, game: game, visibleRooms: visibleRooms)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func drawBatches(_ batches: [Batch], enc: MTLRenderCommandEncoder, roomId: Int?, activeRoom: Int?, activeScreen: MTLTexture?) {
        for b in batches {
            let mode = b.key.mode
            var emissive = b.key.emissive
            var contentAspect: Float = 0
            var texture: MTLTexture = white
            var textured: Float = 0
            if let key = b.key.texture {
                textured = 1
                if mode == ShadingMode.screen.rawValue, let rid = roomId {
                    if rid == activeRoom, let active = activeScreen {
                        texture = active
                        contentAspect = Float(active.width) / Float(max(1, active.height))
                    } else if let idle = textures[key] {
                        texture = idle
                        emissive = 0.45 // inactive screens show dim preview signage
                    } else {
                        texture = black
                    }
                } else {
                    texture = textures[key] ?? black
                }
            }
            // Room lamps, step lights and neon dim with the house lights.
            if let rid = roomId, rid == activeRoom, mode == ShadingMode.emissive.rawValue || mode == ShadingMode.emissiveTextured.rawValue {
                emissive *= max(0.12, houseLights)
            }
            var u = DrawUniforms(
                model: matrix_identity_float4x4,
                baseColor: Vec4(1, 1, 1, 1),
                emissive: Vec4(contentAspect, CinemaWorld.screenSize.x / CinemaWorld.screenSize.y, 0, emissive),
                params: Vec4(b.key.roughness, b.key.metallic, Float(mode), textured)
            )
            enc.setVertexBuffer(b.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setFragmentTexture(texture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.count)
        }
    }

    private func drawCube(_ enc: MTLRenderCommandEncoder, model: simd_float4x4, color: Vec4, emissive: Float = 0, rough: Float = 0.6, metal: Float = 0) {
        var u = DrawUniforms(model: model, baseColor: color, emissive: Vec4(0, 0, 0, emissive),
                             params: Vec4(rough, metal, Float(emissive > 0 ? ShadingMode.emissive.rawValue : ShadingMode.lit.rawValue), 0))
        enc.setVertexBuffer(cube, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentTexture(white, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cubeCount)
    }

    private func drawDynamic(enc: MTLRenderCommandEncoder, game: CinemaGame, visibleRooms: [Int]) {
        let zone = game.zone
        let nearHall: Bool = { if case .lobby = zone { return game.position.z > 14 } ; return true }()
        if nearHall {
            for id in 1...12 {
                let room = CinemaRooms.room(id)
                let side: Float = id <= 6 ? -1 : 1
                let x = side * (CinemaWorld.hallHalfWidth + 0.12)
                let mid = CinemaWorld.roomBaseZ(id) + (CinemaWorld.doorZ0 + CinemaWorld.doorZ1) / 2
                let open = game.doorOpen[id]
                for dir in [-1, 1] as [Float] {
                    let z = mid + dir * (0.5 + open * 0.95)
                    let m = Mat4.translation(Vec3(x, CinemaWorld.doorHeight / 2, z)) * Mat4.scale(Vec3(0.08, CinemaWorld.doorHeight, 1.0))
                    drawCube(enc, model: m, color: Vec4(room.theme.wall.x * 1.5 + 0.05, room.theme.wall.y * 1.5 + 0.05, room.theme.wall.z * 1.5 + 0.05, 1), rough: 0.35, metal: 0.4)
                }
                // Access light: green when your ticket (or admin override) unlocks the room.
                let lamp = game.isUnlocked(id) ? Vec4(0.2, 1, 0.35, 1) : Vec4(1, 0.15, 0.1, 1)
                drawCube(enc, model: Mat4.translation(Vec3(x - side * 0.1, CinemaWorld.doorHeight + 0.35, mid)) * Mat4.scale(Vec3(0.06, 0.12, 0.5)), color: lamp, emissive: 2.5)
            }
        }
        // Pulsing marker above the ticketed seat.
        if let t = game.seatTarget, !game.isSeated, visibleRooms.contains(t.room) {
            let s = CinemaWorld.seatPosition(room: t.room, row: t.row, seat: t.seat)
            let pulse = 0.5 + 0.5 * sinf(game.time * 4)
            let m = Mat4.translation(s + Vec3(0, 1.75 + 0.08 * pulse, 0)) * Mat4.rotationY(game.time) * Mat4.scale(Vec3(0.28, 0.28, 0.28))
            drawCube(enc, model: m, color: Vec4(1, 0.8, 0.3, 1), emissive: 2 + 2 * pulse)
        }
        // Third-person avatar.
        if game.cameraMode == .thirdPerson && !game.isSeated {
            let base = Mat4.translation(game.position) * Mat4.rotationY(game.yaw)
            drawCube(enc, model: base * Mat4.translation(Vec3(0, 0.45, 0)) * Mat4.scale(Vec3(0.34, 0.9, 0.24)), color: Vec4(0.15, 0.17, 0.25, 1))
            drawCube(enc, model: base * Mat4.translation(Vec3(0, 1.2, 0)) * Mat4.scale(Vec3(0.5, 0.65, 0.3)), color: Vec4(0.75, 0.1, 0.12, 1))
            drawCube(enc, model: base * Mat4.translation(Vec3(0, 1.7, 0)) * Mat4.scale(Vec3(0.26, 0.28, 0.26)), color: Vec4(0.85, 0.65, 0.5, 1))
        }
    }

    // MARK: Screen content

    private func updateScreenContent(session: TheaterSession, dt: Double) {
        if let engine = session.screenEngine {
            let eid = ObjectIdentifier(engine)
            if eid != lastScreenEngineId { videoTexture = nil; lastScreenEngineId = eid }
            if let pb = engine.copyLatestPixelBuffer(), let cache = textureCache {
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                var cv: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cv)
                if let cv, let tex = CVMetalTextureGetTexture(cv) {
                    videoTexture = tex
                    retainedCV.append(cv)
                    if retainedCV.count > 4 { retainedCV.removeFirst() }
                }
            }
        } else {
            videoTexture = nil
            lastScreenEngineId = nil
        }
        if session.showsIdent {
            identTimer += dt
            if identTexture == nil || identTimer > 0.1 {
                identTimer = 0
                identTexture = factory.ident(phase: Double(game?.time ?? 0))
            }
        }
        if session.slideVersion != slideVersion {
            slideVersion = session.slideVersion
            let accent = session.ticket.map { CinemaRooms.room($0.roomId).theme.accent } ?? Vec3(1, 0.8, 0.3)
            slideTexture = factory.slide(lines: session.slideLines, accent: accent)
        }
    }

    private func activeScreenTexture(session: TheaterSession) -> MTLTexture? {
        guard session.isRunning else { return nil }
        if session.screenEngine != nil { return videoTexture ?? black }
        if session.showsIdent { return identTexture }
        return slideTexture
    }
}
