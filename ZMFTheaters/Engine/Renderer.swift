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
    private let beamPipeline: MTLRenderPipelineState
    private let prefilterPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let averagePipeline: MTLComputePipelineState
    private let anaglyphPipeline: MTLComputePipelineState
    private let motionPipeline: MTLComputePipelineState
    private let motionGrid: MTLBuffer
    private var motionGridValid = false
    /// ZMF DepthCinema AI (created on first 3D screening — loading the model takes a moment).
    private(set) lazy var depth = DepthEngine()
    private var depthMap: MTLTexture?
    private var depthVersion = -1
    private var stereoTexture: MTLTexture?
    private(set) var stereoActive = false
    let fourDX = FourDXEngine()
    /// ZMF roller-coaster intro (built on the first screening that uses it).
    private lazy var coaster: CoasterScene? = CoasterScene(device: device, factory: factory)
    private var coasterTexture: MTLTexture?
    private(set) var coasterTime: Double = 0
    private var coasterActive = false
    let announcer = ZMFCoasterAnnouncer()
    private let depthState: MTLDepthStencilState
    private let depthReadState: MTLDepthStencilState
    private var depthTexture: MTLTexture?
    private var hdrTexture: MTLTexture?
    private var bloomA: MTLTexture?
    private var bloomB: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    private let inflight = DispatchSemaphore(value: 3)
    let factory: TextureFactory

    private var lobbyBatches: [Batch] = []
    private var roomBatches: [Int: [Batch]] = [:]
    private var beamBatches: [Int: Batch] = [:]
    private let quad: MTLBuffer
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
    weak var youtubeCinema: YouTubeCinemaSession?
    weak var goveeIOS: GoveeIOSController?
    private var lastSceneColorTick: CFTimeInterval = 0
    private var lastNativeLightSample: CFAbsoluteTime = 0
    var settings = AppSettings()
    var thermalThrottle = false
    /// Names of friends in the current watch party (shown seated beside you).
    var partyGuests: [String] = []
    /// Snacks you're carrying appear on your armrest while seated.
    var carrying: (food: Bool, drink: Bool) = (false, false)

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
        pd.colorAttachments[0].pixelFormat = .rgba16Float
        pd.depthAttachmentPixelFormat = .depth32Float
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd),
              let avgFn = library.makeFunction(name: "screen_average"),
              let avg = try? device.makeComputePipelineState(function: avgFn) else { return nil }
        self.pipeline = pipeline
        self.averagePipeline = avg
        guard let anaFn = library.makeFunction(name: "anaglyph_convert"),
              let ana = try? device.makeComputePipelineState(function: anaFn) else { return nil }
        self.anaglyphPipeline = ana
        guard let motFn = library.makeFunction(name: "motion_grid"),
              let mot = try? device.makeComputePipelineState(function: motFn),
              let grid = device.makeBuffer(length: MemoryLayout<Float>.stride * 32 * 18, options: .storageModeShared) else { return nil }
        self.motionPipeline = mot
        self.motionGrid = grid

        // Additive light volume for the projector beam.
        pd.label = "ZMF Projector Beam"
        pd.fragmentFunction = library.makeFunction(name: "beam_fragment")
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].rgbBlendOperation = .add
        pd.colorAttachments[0].sourceRGBBlendFactor = .one
        pd.colorAttachments[0].destinationRGBBlendFactor = .one
        pd.colorAttachments[0].alphaBlendOperation = .add
        pd.colorAttachments[0].sourceAlphaBlendFactor = .zero
        pd.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let beam = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        beamPipeline = beam

        func post(_ fragment: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.label = fragment
            d.vertexFunction = library.makeFunction(name: "post_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let pre = post("bloom_prefilter", .rgba16Float),
              let blur = post("bloom_blur", .rgba16Float),
              let comp = post("composite", .bgra8Unorm_srgb) else { return nil }
        prefilterPipeline = pre
        blurPipeline = blur
        compositePipeline = comp

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds
        dd.isDepthWriteEnabled = false
        guard let dr = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthReadState = dr

        let cubeVerts = WorldGeometry.unitCube()
        let qb = MeshBuilder()
        qb.quad(Vec3(-0.5, -0.5, 0), Vec3(0.5, -0.5, 0), Vec3(0.5, 0.5, 0), Vec3(-0.5, 0.5, 0), normal: Vec3(0, 0, 1), color: Vec4(1, 1, 1, 1), mat: .lit())
        let quadVerts = qb.batches.values.first ?? []
        guard let qbuf = device.makeBuffer(bytes: quadVerts, length: quadVerts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared),
              let cb = device.makeBuffer(bytes: cubeVerts, length: cubeVerts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared),
              let avgBuf = device.makeBuffer(length: MemoryLayout<Vec4>.stride * 65, options: .storageModeShared),
              let w = factory.solid(Vec4(1, 1, 1, 1)),
              let b = factory.solid(Vec4(0, 0, 0, 1)) else { return nil }
        quad = qbuf
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
            let beam = MeshBuilder()
            WorldGeometry.projectorBeam(room, beam)
            beamBatches[room.id] = upload(beam).first
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
        let targetLight: Float = youtubeCinema?.isOpen == true ? 0.12 : session.targetLights
        houseLights += (targetLight - houseLights) * min(1, dt * 0.45)

        updateScreenContent(session: session, dt: Double(dt))
        if timestamp - lastSceneColorTick >= 0.23 {
            lastSceneColorTick = timestamp
            if youtubeCinema?.playing == true, let youtubeCinema, youtubeCinema.video != nil {
                goveeIOS?.sceneColor(
                    CinemaLightPalette.youtubeRhythm(seconds: youtubeCinema.playbackTime, preset: youtubeCinema.preset),
                    source: "YouTube: rhythmic fallback (protected video frames inaccessible)")
            } else if session.phase != .feature || session.feature.player.rate <= 0 {
                goveeIOS?.playbackStopped()
            }
        }

        let size = layer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        if depthTexture == nil || depthTexture!.width != Int(size.width) || depthTexture!.height != Int(size.height) {
            let w = Int(size.width), h = Int(size.height)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            d.usage = .renderTarget
            d.storageMode = .memoryless
            depthTexture = device.makeTexture(descriptor: d)
            let hd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            hd.usage = [.renderTarget, .shaderRead]
            hd.storageMode = .private
            hdrTexture = device.makeTexture(descriptor: hd)
            let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w / 4), height: max(1, h / 4), mipmapped: false)
            bd.usage = [.renderTarget, .shaderRead]
            bd.storageMode = .private
            bloomA = device.makeTexture(descriptor: bd)
            bloomB = device.makeTexture(descriptor: bd)
        }
        guard let hdr = hdrTexture, let bloomA, let bloomB else { return }

        inflight.wait()
        guard let drawable = layer.nextDrawable(), let cmd = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }

        let activeRoom = youtubeCinema?.isOpen == true ? game.seatedAt?.room : session.roomId
        updateCoaster(cmd, session: session, dt: Double(dt))
        convertTo3DIfNeeded(cmd, session: session)
        let activeScreen = activeScreenTexture(session: session)
        apply4DX(session: session, game: game, dt: dt)
        // Fine luminance grid of the film frame for next frame's motion tracking.
        if fourDX.running, session.phase == .feature, let video = videoTexture, let enc = cmd.makeComputeCommandEncoder() {
            enc.setComputePipelineState(motionPipeline)
            enc.setTexture(video, index: 0)
            enc.setBuffer(motionGrid, offset: 0, index: 0)
            enc.dispatchThreadgroups(MTLSize(width: 4, height: 3, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 6, depth: 1))
            enc.endEncoding()
            motionGridValid = true
        } else { motionGridValid = false }

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
        let seatedFov = Float(settings.seatedFieldOfView) * .pi / 180
        let proj = Mat4.perspective(fovyRadians: game.isSeated ? seatedFov : 1.1, aspect: aspect, near: 0.05, far: 160)
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
            if id == activeRoom, fourDX.running {
                // Fog is simulated with distance-haze shading, not physical mist.
                let intensity = Float(max(0, min(1, settings.fourDXAtmosphereStrength)))
                let fog = settings.fourDXVirtualFog ? fourDX.virtualFog : 0
                let mist = settings.fourDXVirtualMist ? fourDX.mist : 0
                frame.fog.w += intensity * (fog * 0.027 + mist * 0.012)
                frame.fog.x += intensity * mist * 0.023
                frame.fog.y += intensity * mist * 0.027
                frame.fog.z += intensity * mist * 0.035
            }
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
        pass.colorAttachments[0].texture = hdr
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
        drawDynamic(enc: enc, game: game, visibleRooms: visibleRooms, activeRoom: activeRoom, cam: cam.eye)

        // Projector beam through the haze, only while something is on screen.
        if settings.projectorBeam, let id = activeRoom, activeScreen != nil, visibleRooms.contains(id), let beam = beamBatches[id] {
            var u = DrawUniforms(model: matrix_identity_float4x4, baseColor: Vec4(1, 1, 1, 1), emissive: Vec4(0, 0, 0, 1), params: Vec4(1, 0, 7, 0))
            enc.setRenderPipelineState(beamPipeline)
            enc.setDepthStencilState(depthReadState)
            enc.setVertexBuffer(beam.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: beam.count)
        }
        enc.endEncoding()

        // Bloom: bright-pass at quarter resolution, then a separable blur.
        let bloomOn = settings.bloomStrength > 0.01
        if bloomOn {
            var pre = Vec4(1.0, 0, 1 / Float(hdr.width) * 2, 1 / Float(hdr.height) * 2)
            postPass(cmd, target: bloomA, pipeline: prefilterPipeline, textures: [hdr], params: &pre)
            var h = Vec4(1 / Float(bloomA.width), 0, 0, 0)
            postPass(cmd, target: bloomB, pipeline: blurPipeline, textures: [bloomA], params: &h)
            var v = Vec4(0, 1 / Float(bloomA.height), 0, 0)
            postPass(cmd, target: bloomA, pipeline: blurPipeline, textures: [bloomB], params: &v)
        }
        var comp = Vec4(bloomOn ? Float(settings.bloomStrength) : 0, settings.filmGrain ? 0.018 : 0, game.time.truncatingRemainder(dividingBy: 100), 0.35)
        // 4DX screen layer only while you're seated in the active 4DX screening.
        let fxOn = settings.fourDXScreenEffects && fourDX.running && game.isSeated
        let fxK = Float(max(0, min(1, settings.fourDXAtmosphereStrength))) * 1.4
        let shake = fxOn ? Vec2(sinf(game.time * 61) , cosf(game.time * 53)) * fourDX.rumble * 0.0035 : .zero
        let fx = fxOn ? Vec4(min(1, fourDX.water * fxK), min(1, fourDX.wind * fxK), fourDX.flash, settings.fourDXVirtualMist ? fourDX.mist * fxK * 0.5 : 0) : .zero
        let jolt = fxOn ? Vec2(fourDX.seatTilt.y, fourDX.seatTilt.x) * fourDX.hitFx * 0.02 : .zero
        let fx2 = Vec4(aspect, game.time.truncatingRemainder(dividingBy: 600), shake.x + jolt.x, shake.y + jolt.y)
        let fx3 = fxOn ? Vec4(fourDX.shock, fourDX.embers * fxK, fourDX.smoke * fxK * 0.8, fourDX.debrisFx) : .zero
        let fx4 = fxOn ? Vec4(fourDX.hitFx, 0, 0, 0) : .zero
        postPass(cmd, target: drawable.texture, pipeline: compositePipeline, textures: [hdr, bloomOn ? bloomA : black], params: &comp, extra: [fx, fx2, fx3, fx4])

        cmd.present(drawable)
        cmd.commit()
    }

    private func postPass(_ cmd: MTLCommandBuffer, target: MTLTexture, pipeline: MTLRenderPipelineState, textures: [MTLTexture], params: inout Vec4, extra: [Vec4] = []) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
        enc.setFragmentBytes(&params, length: MemoryLayout<Vec4>.stride, index: 0)
        for (i, v) in extra.enumerated() { var copy = v; enc.setFragmentBytes(&copy, length: MemoryLayout<Vec4>.stride, index: 1 + i) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
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
                    if youtubeCinema?.isOpen == true && rid == activeRoom {
                        // The native WKWebView is world-anchored exactly on top
                        // of this screen. Hide old static signage beneath it.
                        texture = black
                        emissive = 0.15
                    } else if rid == activeRoom, let active = activeScreen {
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

    private func drawTag(_ enc: MTLRenderCommandEncoder, at p: Vec3, cam: Vec3, texture: MTLTexture) {
        let a = atan2f(cam.x - p.x, cam.z - p.z)
        var u = DrawUniforms(model: Mat4.translation(p) * Mat4.rotationY(a) * Mat4.scale(Vec3(0.72, 0.18, 1)),
                             baseColor: Vec4(1, 1, 1, 1), emissive: Vec4(0, 0, 0, 1.4),
                             params: Vec4(1, 0, Float(ShadingMode.emissiveTextured.rawValue), 1))
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private static func color(for name: String) -> Vec4 {
        var h: UInt32 = 2166136261
        for b in name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let palette: [Vec4] = [Vec4(0.8, 0.15, 0.2, 1), Vec4(0.15, 0.45, 0.85, 1), Vec4(0.2, 0.7, 0.35, 1),
                               Vec4(0.85, 0.6, 0.15, 1), Vec4(0.55, 0.25, 0.8, 1), Vec4(0.1, 0.7, 0.75, 1)]
        return palette[Int(h % UInt32(palette.count))]
    }

    /// A seated moviegoer facing the screen of `room`.
    private func drawSeatedFigure(_ enc: MTLRenderCommandEncoder, room: Int, row: Int, seat: Int, shirt: Vec4, skin: Vec4) {
        let base = Mat4.translation(CinemaWorld.seatPosition(room: room, row: row, seat: seat)) * Mat4.rotationY(CinemaWorld.screenYaw(room))
        drawCube(enc, model: base * Mat4.translation(Vec3(0, 0.88, -0.12)) * Mat4.scale(Vec3(0.44, 0.58, 0.26)), color: shirt, rough: 0.8)
        drawCube(enc, model: base * Mat4.translation(Vec3(0, 1.3, -0.1)) * Mat4.scale(Vec3(0.22, 0.26, 0.24)), color: skin, rough: 0.7)
        drawCube(enc, model: base * Mat4.translation(Vec3(0, 1.45, -0.12)) * Mat4.scale(Vec3(0.24, 0.07, 0.26)), color: Vec4(0.12, 0.08, 0.06, 1), rough: 0.9)
        drawCube(enc, model: base * Mat4.translation(Vec3(0, 0.6, 0.2)) * Mat4.scale(Vec3(0.4, 0.16, 0.5)), color: Vec4(0.15, 0.17, 0.25, 1), rough: 0.9)
        drawCube(enc, model: base * Mat4.translation(Vec3(0.26, 0.82, 0.08)) * Mat4.scale(Vec3(0.1, 0.1, 0.4)), color: shirt, rough: 0.8)
        drawCube(enc, model: base * Mat4.translation(Vec3(-0.26, 0.82, 0.08)) * Mat4.scale(Vec3(0.1, 0.1, 0.4)), color: shirt, rough: 0.8)
    }

    private func drawDynamic(enc: MTLRenderCommandEncoder, game: CinemaGame, visibleRooms: [Int], activeRoom: Int?, cam: Vec3) {
        // The occupied motion rig is animated by the real playback-clock 4DX
        // signal. These are virtual mechanics only; no physical chair moves.
        if let seat = game.seatedAt, seat.room == activeRoom,
           visibleRooms.contains(seat.room), fourDX.running {
            let base = CinemaWorld.seatPosition(room: seat.room, row: seat.row, seat: seat.seat)
            let yaw = CinemaWorld.screenYaw(seat.room)
            let travel = game.seatMotion.offset
            let pitch = max(-0.10, min(0.10, game.seatMotion.tilt.x))
            let bank = max(-0.10, min(0.10, game.seatMotion.tilt.y))
            let body = Mat4.translation(base + travel * 0.85) *
                Mat4.rotationY(yaw) * Mat4.rotationZ(bank) * Mat4.rotationX(pitch)
            let steel = Vec4(0.42, 0.48, 0.54, 1)
            let black = Vec4(0.055, 0.065, 0.08, 1)
            let glow = Vec4(0.12, 0.72, 0.91, 1)
            drawCube(enc, model: Mat4.translation(base + Vec3(0, 0.1, 0)) * Mat4.scale(Vec3(0.66, 0.13, 0.72)),
                     color: black, rough: 0.5, metal: 0.65)
            for x in [-0.25, 0.25] as [Float] {
                for z in [-0.26, 0.26] as [Float] {
                    let jack = base + Vec3(x, 0.24 + travel.y * 0.4, z)
                    drawCube(enc, model: Mat4.translation(jack) * Mat4.scale(Vec3(0.065, 0.3, 0.065)),
                             color: steel, rough: 0.3, metal: 0.8)
                    drawCube(enc, model: Mat4.translation(jack + Vec3(0, 0.13, 0)) * Mat4.scale(Vec3(0.12, 0.045, 0.12)),
                             color: glow, emissive: 0.8)
                }
            }
            drawCube(enc, model: body * Mat4.translation(Vec3(0, 0.48, 0)) * Mat4.scale(Vec3(0.7, 0.14, 0.84)),
                     color: black, rough: 0.8)
            drawCube(enc, model: body * Mat4.translation(Vec3(0.51, 0.8, 0)) * Mat4.scale(Vec3(0.13, 0.72, 0.77)),
                     color: Vec4(0.12, 0.16, 0.22, 1), rough: 0.82)
        }
        drawVirtualAtmosphere(enc: enc, game: game, activeRoom: activeRoom)

        // Friends from the watch party sit next to you.
        if let s = game.seatedAt, s.room == activeRoom, visibleRooms.contains(s.room), !partyGuests.isEmpty {
            let order = [1, -1, 2, -2, 3, -3, 4, -4].map { s.seat + $0 }.filter { (0..<Seating.seatsPerRow).contains($0) }
            for (i, name) in partyGuests.prefix(order.count).enumerated() {
                let seat = order[i]
                drawSeatedFigure(enc, room: s.room, row: s.row, seat: seat, shirt: Self.color(for: name), skin: Vec4(0.8, 0.62, 0.5, 1))
                if let tag = textures["party.name.\(i)"] {
                    drawTag(enc, at: CinemaWorld.seatPosition(room: s.room, row: s.row, seat: seat) + Vec3(0, 1.78, 0), cam: cam, texture: tag)
                }
            }
        }
        // Snacks on your armrest.
        if let s = game.seatedAt, carrying.food || carrying.drink {
            let t = CinemaWorld.transform(room: s.room)
            let fl = CinemaWorld.rowFloor(s.row)
            let x = CinemaWorld.rowX(s.row), z = CinemaWorld.seatZ(s.seat)
            if carrying.drink {
                let p = t.point(Vec3(x - 0.22, fl + 0.86, z - 0.47))
                drawCube(enc, model: Mat4.translation(p) * Mat4.scale(Vec3(0.08, 0.2, 0.08)), color: Vec4(0.85, 0.1, 0.12, 1), rough: 0.4)
                drawCube(enc, model: Mat4.translation(p + Vec3(0, 0.14, 0)) * Mat4.scale(Vec3(0.012, 0.12, 0.012)), color: Vec4(1, 1, 1, 1), rough: 0.4)
            }
            if carrying.food {
                let p = t.point(Vec3(x + 0.1, fl + 0.88, z - 0.47))
                drawCube(enc, model: Mat4.translation(p) * Mat4.scale(Vec3(0.16, 0.22, 0.16)), color: Vec4(0.9, 0.9, 0.88, 1), rough: 0.6)
                drawCube(enc, model: Mat4.translation(p + Vec3(0, 0.002, 0)) * Mat4.scale(Vec3(0.165, 0.06, 0.165)), color: Vec4(0.8, 0.08, 0.1, 1), rough: 0.6)
                drawCube(enc, model: Mat4.translation(p + Vec3(0, 0.13, 0)) * Mat4.scale(Vec3(0.15, 0.06, 0.15)), color: Vec4(1, 0.88, 0.5, 1), rough: 0.9)
            }
        }

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

    /// Procedural 4DX visual preset effects in the *virtual* auditorium.
    /// Screen content is never edited or assumed to contain snow, fog or fire.
    /// Total < 42 small meshes/frame, drawn only in the active occupied room.
    private func drawVirtualAtmosphere(enc: MTLRenderCommandEncoder, game: CinemaGame, activeRoom: Int?) {
        guard fourDX.running, let activeRoom, let occupied = game.seatedAt,
              occupied.room == activeRoom else { return }
        let strength = Float(max(0, min(1, settings.fourDXAtmosphereStrength)))
        guard strength > 0.01 else { return }
        let current = CinemaWorld.seatPosition(room: occupied.room, row: occupied.row, seat: occupied.seat)
        let forward = forwardVector(yaw: CinemaWorld.screenYaw(occupied.room))
        let side = simd_cross(forward, Vec3(0, 1, 0))
        let t = game.time

        func part(_ index: Int, kind: Int, intensity: Float, tint: Vec4) {
            guard intensity > 0.1 else { return }
            let fi = Float(index)
            let seed = fi * 12.9898 + Float(kind) * 78.233
            let u = sinf(seed) * 43758.545
            let fraction = u - floorf(u)
            let v = sinf(seed + 19.2) * 5931.21
            let fraction2 = v - floorf(v)
            let speed: Float = kind == 0 ? 0.8 : (kind == 1 ? 0.52 : 0.18)
            let fall = kind == 2 ? -1 : 1
            let y = (fraction * 3.5 + t * speed * Float(fall)).truncatingRemainder(dividingBy: 3.5)
            let pos = current + forward * (2.0 + fraction * 5.0) +
                side * ((fraction2 - 0.5) * 7.0) + Vec3(0, 0.8 + y, 0)
            let size: Float = kind == 1 ? 0.018 : (kind == 0 ? 0.026 : 0.018)
            drawCube(enc, model: Mat4.translation(pos) * Mat4.scale(Vec3(size, size, size) * max(0.4, intensity)),
                     color: tint, emissive: kind == 1 ? 0.3 : 0)
        }
        if settings.fourDXVirtualSnow {
            for i in 0..<22 {
                part(i, kind: 0, intensity: fourDX.snow * strength, tint: Vec4(0.85, 0.93, 1, 1))
            }
        }
        if settings.fourDXVirtualAsh {
            for i in 0..<18 {
                part(i, kind: 1, intensity: fourDX.ash * strength, tint: Vec4(0.53, 0.43, 0.37, 1))
            }
        }
        // Embers from detected booms drift through the auditorium.
        if fourDX.embers > 0.1 {
            for i in 0..<20 {
                part(i + 40, kind: 1, intensity: fourDX.embers * max(0.5, strength), tint: Vec4(1, 0.45, 0.12, 1))
            }
        }
        // Mist/fog volume comes from the existing shader's smooth distance haze.
        // A handful of faint light flecks makes the mist visible near projectors.
        if settings.fourDXVirtualMist && fourDX.mist > 0.18 {
            for i in 0..<8 {
                part(i, kind: 2, intensity: fourDX.mist * strength, tint: Vec4(0.56, 0.68, 0.78, 1))
            }
        }
    }

    // MARK: Roller-coaster intro

    private func updateCoaster(_ cmd: MTLCommandBuffer, session: TheaterSession, dt: Double) {
        let want = session.showsIdent && settings.coasterIntro
        if want && !coasterActive { coasterTime = 0; announcer.reset() }
        if !want && coasterActive { announcer.reset(); coasterTexture = nil }
        coasterActive = want
        guard want else { return }
        coasterTime += dt
        announcer.enabled = settings.coasterVoice
        announcer.update(time: coasterTime)
        let stereo = session.ticket?.screeningFormat.usesDepth == true
        coasterTexture = coaster?.render(cmd, time: coasterTime, stereo: stereo)
    }

    // MARK: 3D conversion

    private func wants3D(_ session: TheaterSession) -> Bool {
        session.ticket?.screeningFormat.usesDepth == true && session.screenEngine === session.feature
    }

    /// Uploads the newest stabilised depth map and synthesises the red/cyan frame.
    private func convertTo3DIfNeeded(_ cmd: MTLCommandBuffer, session: TheaterSession) {
        stereoActive = false
        guard wants3D(session), let video = videoTexture, depth.isAvailable, let map = depth.latest else { return }
        if map.version != depthVersion {
            if depthMap == nil || depthMap!.width != map.width || depthMap!.height != map.height {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: map.width, height: map.height, mipmapped: false)
                d.usage = .shaderRead
                depthMap = device.makeTexture(descriptor: d)
            }
            map.values.withUnsafeBytes { raw in
                depthMap?.replace(region: MTLRegionMake2D(0, 0, map.width, map.height), mipmapLevel: 0,
                                  withBytes: raw.baseAddress!, bytesPerRow: map.width * MemoryLayout<Float>.stride)
            }
            depthVersion = map.version
        }
        guard let depthMap else { return }
        let scale = min(1, 1920 / Double(video.width))
        let w = max(2, Int(Double(video.width) * scale)), h = max(2, Int(Double(video.height) * scale))
        if stereoTexture == nil || stereoTexture!.width != w || stereoTexture!.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            stereoTexture = device.makeTexture(descriptor: d)
        }
        guard let out = stereoTexture, let enc = cmd.makeComputeCommandEncoder() else { return }
        var params = Vec4(Float(settings.stereoSeparation * settings.depthIntensity), Float(settings.convergence),
                          Float(settings.ghostingReduction), Float(max(0.4, 1.6 - settings.depthIntensity * 0.6)))
        enc.setComputePipelineState(anaglyphPipeline)
        enc.setTexture(video, index: 0)
        enc.setTexture(depthMap, index: 1)
        enc.setTexture(out, index: 2)
        enc.setBytes(&params, length: MemoryLayout<Vec4>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()
        stereoActive = true
    }

    /// Human-readable 3D state for the screening controls.
    func stereoStatus(for session: TheaterSession) -> String? {
        guard session.ticket?.screeningFormat.usesDepth == true else { return nil }
        if !depth.isAvailable { return "3D unavailable (\(depth.loadError ?? "no model")) · playing 2D" }
        if stereoActive { return String(format: "3D · depth %.0f Hz · wear red/cyan glasses", depth.measuredHz) }
        return "3D · estimating depth…"
    }

    // MARK: 4DX

    private func apply4DX(session: TheaterSession, game: CinemaGame, dt: Float) {
        let feature4DX = session.ticket?.screeningFormat.uses4DX == true && session.phase == .feature &&
            session.feature.player.rate > 0 && FourDX.isPreviewActive(settings: settings)
        let trailer4DX = session.activeYouTubeTrailer?.presentation.uses4DX == true &&
            session.phase == .trailer && session.youtubeIsPlaying && settings.fourDXTrailersEnabled
        let youTube4DX = youtubeCinema?.isOpen == true && youtubeCinema?.format.uses4DX == true &&
            youtubeCinema?.playing == true && youtubeCinema?.preset != .off
        let ride4DX = coasterActive && session.ticket?.screeningFormat.uses4DX == true
        let want = feature4DX || trailer4DX || youTube4DX || ride4DX
        if feature4DX, let ticket = session.ticket {
            fourDX.beginMedia(id: ticket.mediaId, duration: session.feature.duration)
        }
        fourDX.flashesAllowed = settings.fourDXScreenFlashes
        fourDX.hapticStrength = Float(max(0, min(1, settings.fourDXHapticStrength)))
        if want && !fourDX.running { fourDX.start(haptics: settings.fourDXHaptics) }
        if !want && fourDX.running { fourDX.stop() }
        let grid = screenAverage.contents().bindMemory(to: Vec4.self, capacity: 65).advanced(by: 1)
        let forward = game.seatedAt.map { forwardVector(yaw: CinemaWorld.screenYaw($0.room)) } ?? Vec3(0, 0, 1)
        if ride4DX {
            let cue = ZMFCoasterTrack.shared.seatCue(at: coasterTime)
            let up = Vec3(0, 1, 0)
            let right = simd_normalize(simd_cross(forward, up))
            let offset = right * cue.offset.x + up * cue.offset.y - forward * cue.offset.z
            fourDX.updateRide(dt: dt, offset: offset, tilt: cue.tilt, rumble: cue.rumble, wind: cue.wind,
                              water: cue.water, flash: cue.flash, intensity: Float(settings.fourDXIntensity))
        } else if youTube4DX, let youtubeCinema {
            fourDX.updateYouTubeCinema(dt: dt, timestamp: youtubeCinema.playbackTime,
                  intensity: Float(settings.fourDXIntensity), seatForward: forward,
                  preset: youtubeCinema.preset, bpm: youtubeCinema.bpm,
                  cuts: youtubeCinema.cutMarks)
        } else if trailer4DX {
            fourDX.updateTrailerPreview(dt: dt, timestamp: session.youtubeTime,
                                       intensity: Float(settings.fourDXIntensity), seatForward: forward)
        } else {
            let fine = feature4DX && motionGridValid
                ? UnsafeBufferPointer(start: motionGrid.contents().bindMemory(to: Float.self, capacity: 32 * 18), count: 32 * 18) : nil
            let audio = feature4DX ? (session.feature.audioTap?.drain() ?? []) : []
            fourDX.update(grid: feature4DX ? UnsafePointer(grid) : nil, dt: dt,
                          intensity: Float(settings.fourDXIntensity), seatForward: forward,
                          timestamp: session.feature.player.currentTime().seconds,
                          fineGrid: fine, audio: audio)
        }
        let travel = Float(max(0, min(1.5, settings.fourDXSeatTravel)))
        game.seatMotion = (fourDX.seatOffset * travel, fourDX.seatTilt * travel)
    }

    // MARK: Screen content

    private func updateScreenContent(session: TheaterSession, dt: Double) {
        if let engine = session.screenEngine {
            let eid = ObjectIdentifier(engine)
            if eid != lastScreenEngineId { videoTexture = nil; lastScreenEngineId = eid }
            if let pb = engine.copyLatestPixelBuffer(), let cache = textureCache {
                if session.phase == .feature && session.feature.player.rate > 0,
                   CFAbsoluteTimeGetCurrent() - lastNativeLightSample >= 0.34 {
                    lastNativeLightSample = CFAbsoluteTimeGetCurrent()
                    if let palette = CinemaLightPalette.nativeMovieFrame(pb) {
                        goveeIOS?.sceneColor(palette, source: "Decoded film: sampled on iPhone")
                    }
                }
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                var cv: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cv)
                if session.ticket?.screeningFormat.usesDepth == true, engine === session.feature {
                    depth.submit(pb, rate: settings.depthUpdatesPerSecond)
                }
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
        if session.screenEngine != nil { return (stereoActive ? stereoTexture : nil) ?? videoTexture ?? black }
        if session.showsIdent { return (settings.coasterIntro ? coasterTexture : nil) ?? identTexture }
        return slideTexture
    }
}

