import UIKit
import Metal
import simd

/// Renders the ZMF THEATERS roller-coaster intro to an offscreen texture that
/// the auditorium screen shows during the ZMF presentation. Optional true
/// stereo: left and right eyes are drawn into the red and green/blue
/// channels for red/cyan glasses (real geometry depth, not converted 2D).
@MainActor
final class CoasterScene {
    private struct Batch { var key: MaterialKey; var buffer: MTLBuffer; var count: Int }

    private let device: MTLDevice
    private let mono: MTLRenderPipelineState
    private let leftEye: MTLRenderPipelineState
    private let rightEye: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var batches: [Batch] = []
    private var textures: [String: MTLTexture] = [:]
    private let white: MTLTexture
    private let cube: MTLBuffer
    private let cubeCount: Int
    private let average: MTLBuffer
    private var color: MTLTexture?
    private var depth: MTLTexture?
    private var lights: [(Vec3, Vec3, Float, Float)] = []   // position, colour, intensity, range
    private let track = ZMFCoasterTrack.shared
    let width = 1280, height = 544

    init?(device: MTLDevice, factory: TextureFactory) {
        guard let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2; vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0
        vd.attributes[3].format = .float4; vd.attributes[3].offset = 32; vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<Vertex>.stride
        func make(_ mask: MTLColorWriteMask) -> MTLRenderPipelineState? {
            let pd = MTLRenderPipelineDescriptor()
            pd.label = "ZMF Coaster"
            pd.vertexFunction = library.makeFunction(name: "cinema_vertex")
            pd.fragmentFunction = library.makeFunction(name: "cinema_fragment")
            pd.vertexDescriptor = vd
            pd.colorAttachments[0].pixelFormat = .rgba16Float
            pd.colorAttachments[0].writeMask = mask
            pd.depthAttachmentPixelFormat = .depth32Float
            return try? device.makeRenderPipelineState(descriptor: pd)
        }
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        let cubeVerts = WorldGeometry.unitCube()
        guard let m = make(.all), let l = make(.red), let r = make([.green, .blue, .alpha]),
              let ds = device.makeDepthStencilState(descriptor: dd),
              let w = factory.solid(Vec4(1, 1, 1, 1)),
              let cb = device.makeBuffer(bytes: cubeVerts, length: cubeVerts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared),
              let avg = device.makeBuffer(length: MemoryLayout<Vec4>.stride * 65, options: .storageModeShared) else { return nil }
        mono = m; leftEye = l; rightEye = r; depthState = ds; white = w
        cube = cb; cubeCount = cubeVerts.count; average = avg

        let gold = UIColor(red: 1, green: 0.8, blue: 0.35, alpha: 1)
        let night = UIColor(red: 0.07, green: 0.01, blue: 0.03, alpha: 1)
        textures["coaster.logo"] = factory.label("ZMF THEATERS", size: CGSize(width: 2048, height: 420),
                                                 font: .systemFont(ofSize: 300, weight: .black), fg: gold, bg: night, border: gold)
        textures["coaster.admit"] = factory.label("ADMIT ONE · ZMF EXPRESS", size: CGSize(width: 1400, height: 200),
                                                  font: .systemFont(ofSize: 120, weight: .heavy), fg: .white,
                                                  bg: UIColor(red: 0.75, green: 0.05, blue: 0.08, alpha: 1), border: gold)
        textures["coaster.enjoy"] = factory.label("ENJOY THE SHOW", size: CGSize(width: 1400, height: 200),
                                                  font: .systemFont(ofSize: 130, weight: .heavy), fg: .white, bg: night, border: gold)
        let b = MeshBuilder()
        buildWorld(b)
        batches = b.batches.compactMap { key, verts in
            guard !verts.isEmpty, let buf = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Vertex>.stride, options: .storageModeShared) else { return nil }
            return Batch(key: key, buffer: buf, count: verts.count)
        }
    }

    // MARK: World

    private func hash(_ n: Float) -> Float { let v = sinf(n * 12.9898) * 43758.545; return v - floorf(v) }

    private func buildWorld(_ b: MeshBuilder) {
        let steel = MaterialKey.lit(rough: 0.25, metal: 0.9)
        let red = Vec4(0.75, 0.04, 0.07, 1)
        // Ground with a glowing grid, like a theme park at night.
        b.box(Vec3(-140, -0.2, -80), Vec3(160, 0, 260), color: Vec4(0.03, 0.03, 0.05, 1), mat: .lit(rough: 0.9))
        for i in stride(from: -140, through: 160, by: 20) {
            b.box(center: Vec3(Float(i), 0.01, 90), size: Vec3(0.08, 0.02, 340), color: Vec4(0.35, 0.1, 0.6, 1), mat: .glow(0.6))
        }
        for k in stride(from: -80, through: 260, by: 20) {
            b.box(center: Vec3(10, 0.01, Float(k)), size: Vec3(300, 0.02, 0.08), color: Vec4(0.35, 0.1, 0.6, 1), mat: .glow(0.6))
        }

        // Track: steel rails, red spine, ties, LED edge lights and supports.
        let L = track.length
        var s: Float = 0
        var n = 0
        while s < L {
            let a = track.point(at: s), c = track.point(at: min(L, s + 1.02))
            let mid = (a + c) * 0.5
            let f = track.frame(atDistance: s + 0.5)
            for side in [-0.55, 0.55] as [Float] {
                b.orientedBox(center: mid + f.right * side, x: f.right, y: f.up, z: f.forward,
                              half: Vec3(0.05, 0.05, 0.53), color: Vec4(0.72, 0.75, 0.8, 1), mat: steel)
                let led = n % 2 == 0 ? Vec4(1, 0.72, 0.25, 1) : Vec4(1, 0.12, 0.12, 1)
                b.orientedBox(center: mid + f.right * (side * 1.16) - f.up * 0.06, x: f.right, y: f.up, z: f.forward,
                              half: Vec3(0.025, 0.025, 0.3), color: led, mat: .glow(2.2))
            }
            b.orientedBox(center: mid - f.up * 0.38, x: f.right, y: f.up, z: f.forward,
                          half: Vec3(0.13, 0.13, 0.52), color: red, mat: .lit(rough: 0.35, metal: 0.6))
            if n % 2 == 0 {
                b.orientedBox(center: mid - f.up * 0.12, x: f.right, y: f.up, z: f.forward,
                              half: Vec3(0.68, 0.035, 0.07), color: Vec4(0.2, 0.2, 0.22, 1), mat: steel)
            }
            if n % 7 == 0 && mid.y > 1.6 {
                let top = mid - f.up * 0.5
                b.box(Vec3(top.x - 0.18, 0, top.z - 0.18), Vec3(top.x + 0.18, top.y, top.z + 0.18), color: Vec4(0.16, 0.17, 0.2, 1), mat: steel)
                b.box(center: Vec3(top.x, 0.15, top.z), size: Vec3(0.9, 0.3, 0.9), color: Vec4(0.3, 0.3, 0.32, 1), mat: .lit(rough: 0.8))
            }
            if n % 30 == 0 { lights.append((mid + Vec3(0, 7, 0), Vec3(1, 0.75, 0.45), 6, 34)) }
            s += 1
            n += 1
        }

        // Station with canopy and the ADMIT ONE arch over the lift entrance.
        b.box(Vec3(-4, 0, -14), Vec3(4, 1.4, 8), color: Vec4(0.12, 0.1, 0.12, 1), mat: .lit(rough: 0.6))
        b.box(Vec3(-5, 5.5, -14), Vec3(5, 5.8, 8), color: red, mat: .lit(rough: 0.4, metal: 0.4))
        for z in stride(from: -12, through: 6, by: 6) {
            for x in [-4.6, 4.6] as [Float] { b.box(center: Vec3(x, 2.8, Float(z)), size: Vec3(0.25, 5.6, 0.25), color: Vec4(0.8, 0.65, 0.3, 1), mat: steel) }
        }
        b.box(center: Vec3(0, 5.4, -3), size: Vec3(8, 0.05, 20), color: Vec4(1, 0.85, 0.6, 1), mat: .glow(1.2))
        let arch = track.point(at: 0.12 * L)
        for x in [-3.5, 3.5] as [Float] { b.box(center: Vec3(arch.x + x, arch.y / 2 + 3, arch.z), size: Vec3(0.5, arch.y + 6, 0.5), color: Vec4(0.85, 0.7, 0.3, 1), mat: steel) }
        b.sign(center: Vec3(arch.x, arch.y + 5.2, arch.z - 0.3), normal: Vec3(0, 0, -1), width: 8, height: 1.15, mat: .glowTex("coaster.admit", 1.4))
        lights.append((Vec3(0, 4, -3), Vec3(1, 0.85, 0.6), 9, 20))

        // Film-reel rings the train flies through.
        for frac in [0.36, 0.5, 0.79] as [Float] {
            let s0 = frac * L
            let p = track.point(at: s0) + track.frame(atDistance: s0).up * 1.0
            let f = track.frame(atDistance: s0)
            let radius: Float = 4.6
            for k in 0..<28 {
                let a0 = Float(k) / 28 * 2 * .pi
                let dir = f.right * cosf(a0) + f.up * sinf(a0)
                let tangentDir = f.right * -sinf(a0) + f.up * cosf(a0)
                b.orientedBox(center: p + dir * radius, x: dir, y: tangentDir, z: f.forward,
                              half: Vec3(0.22, 0.55, 0.3), color: Vec4(0.9, 0.7, 0.25, 1), mat: .lit(rough: 0.25, metal: 0.95))
                if k % 2 == 0 {
                    b.orientedBox(center: p + dir * (radius - 0.3), x: dir, y: tangentDir, z: f.forward,
                                  half: Vec3(0.05, 0.2, 0.32), color: Vec4(1, 0.85, 0.4, 1), mat: .glow(2.5))
                }
            }
            for k in 0..<5 {   // reel holes as glowing sprocket plates
                let a0 = Float(k) / 5 * 2 * .pi + 0.3
                let dir = f.right * cosf(a0) + f.up * sinf(a0)
                b.orientedBox(center: p + dir * (radius + 0.6) + f.forward * 0.4, x: dir, y: simd_cross(f.forward, dir), z: f.forward,
                              half: Vec3(0.5, 0.5, 0.05), color: Vec4(0.2, 0.2, 0.22, 1), mat: steel)
            }
            lights.append((p, Vec3(1, 0.8, 0.4), 5, 16))
        }

        // Giant popcorn buckets around the first drop.
        for (i, base) in [Vec3(-14, 0, 106), Vec3(13, 0, 112), Vec3(-12, 0, 128), Vec3(30, 0, 118)].enumerated() {
            let r: Float = 3.2 + Float(i % 2) * 0.8, h: Float = 9 + Float(i) * 1.5
            for k in 0..<16 {
                let a0 = Float(k) / 16 * 2 * .pi
                let dir = Vec3(cosf(a0), 0, sinf(a0))
                let col = k % 2 == 0 ? Vec4(0.85, 0.06, 0.08, 1) : Vec4(0.95, 0.93, 0.9, 1)
                b.orientedBox(center: base + dir * r + Vec3(0, h / 2, 0), x: dir, y: Vec3(0, 1, 0), z: simd_cross(dir, Vec3(0, 1, 0)),
                              half: Vec3(0.15, h / 2, r * 0.21), color: col, mat: .lit(rough: 0.5))
            }
            for k in 0..<26 {
                let a0 = hash(Float(i * 40 + k)) * 2 * .pi, rr = sqrtf(hash(Float(i * 40 + k) + 3)) * r
                let p = base + Vec3(cosf(a0) * rr, h + 0.2 + hash(Float(k) + 9) * 1.4, sinf(a0) * rr)
                b.box(center: p, size: Vec3(repeating: 0.7 + hash(Float(k) + 1) * 0.5), color: Vec4(1, 0.88, 0.55, 1), mat: .lit(rough: 0.9))
            }
            lights.append((base + Vec3(0, h + 4, 0), Vec3(1, 0.9, 0.7), 5, 20))
        }

        // Splash pool and glowing tunnel arches in the water section.
        let pool = ZMFCoasterTrack.poolCenter
        b.box(Vec3(pool.x - 16, 0, pool.z - 18), Vec3(pool.x + 16, 0.05, pool.z + 18), color: Vec4(0.05, 0.25, 0.5, 1), mat: .lit(rough: 0.05, metal: 0.8))
        b.box(center: Vec3(pool.x, 0.06, pool.z), size: Vec3(32, 0.01, 36), color: Vec4(0.1, 0.5, 0.9, 1), mat: .glow(0.25))
        var arcS = ZMFCoasterTrack.splashRange.lowerBound * L
        while arcS < ZMFCoasterTrack.splashRange.upperBound * L {
            let f = track.frame(atDistance: arcS)
            let p = track.point(at: arcS)
            for side in [-2.2, 2.2] as [Float] {
                b.orientedBox(center: p + f.right * side + f.up * 1.6, x: f.right, y: f.up, z: f.forward, half: Vec3(0.18, 1.8, 0.18),
                              color: Vec4(0.15, 0.6, 0.9, 1), mat: .lit(rough: 0.3, metal: 0.5))
            }
            b.orientedBox(center: p + f.up * 3.4, x: f.right, y: f.up, z: f.forward, half: Vec3(2.4, 0.12, 0.2),
                          color: Vec4(0.3, 0.85, 1, 1), mat: .glow(1.8))
            arcS += 4
        }
        lights.append((pool + Vec3(0, 6, 0), Vec3(0.4, 0.75, 1), 8, 30))

        // Stars and a distant skyline with lit windows.
        for i in 0..<320 {
            let a0 = hash(Float(i)) * 2 * .pi, e = 0.12 + hash(Float(i) + 7) * 1.3
            let p = Vec3(cosf(a0) * cosf(e), sinf(e), sinf(a0) * cosf(e)) * 210 + Vec3(10, 0, 90)
            b.box(center: p, size: Vec3(repeating: 0.5 + hash(Float(i) + 2)), color: Vec4(0.9, 0.92, 1, 1), mat: .glow(1.5 + hash(Float(i) + 5) * 2))
        }
        for i in 0..<70 {
            let a0 = Float(i) / 70 * 2 * .pi, rad: Float = 150 + hash(Float(i) + 11) * 25
            let w: Float = 8 + hash(Float(i)) * 10, h: Float = 14 + hash(Float(i) + 3) * 45
            let c = Vec3(10 + cosf(a0) * rad, h / 2, 90 + sinf(a0) * rad)
            b.box(center: c, size: Vec3(w, h, w), color: Vec4(0.04, 0.04, 0.06, 1), mat: .lit(rough: 0.9))
            let out = simd_normalize(Vec3(cosf(a0), 0, sinf(a0))) * -1
            for wdx in 0..<6 where hash(Float(i * 10 + wdx)) > 0.35 {
                let wy = 3 + hash(Float(i * 10 + wdx) + 1) * (h - 5)
                b.box(center: c + out * (w / 2 + 0.05) + Vec3(0, wy - h / 2, 0) + simd_cross(out, Vec3(0, 1, 0)) * ((hash(Float(wdx)) - 0.5) * w * 0.7),
                      size: Vec3(1.2, 0.8, 1.2), color: Vec4(1, 0.82, 0.5, 1), mat: .glow(1.6))
            }
        }

        // The marquee at the end of the brake run.
        let logo = ZMFCoasterTrack.logoPosition
        b.sign(center: logo, normal: Vec3(0, 0, -1), width: 34, height: 7, mat: .glowTex("coaster.logo", 1.8))
        b.sign(center: logo + Vec3(0, -6, -0.2), normal: Vec3(0, 0, -1), width: 16, height: 2.3, mat: .glowTex("coaster.enjoy", 1.3))
        b.box(Vec3(logo.x - 18, logo.y - 4.4, logo.z + 0.1), Vec3(logo.x + 18, logo.y + 4.4, logo.z + 1.2), color: Vec4(0.1, 0.02, 0.03, 1), mat: .lit(rough: 0.5))
        for k in 0..<72 {
            let t = Float(k) / 72
            let per: Float = 2 * (36 + 8.8)
            var d = t * per
            var p = Vec3.zero
            if d < 36 { p = Vec3(-18 + d, 4.4, 0) } else if d < 44.8 { d -= 36; p = Vec3(18, 4.4 - d, 0) }
            else if d < 80.8 { d -= 44.8; p = Vec3(18 - d, -4.4, 0) } else { d -= 80.8; p = Vec3(-18, -4.4 + d, 0) }
            b.box(center: logo + p + Vec3(0, 0, -0.1), size: Vec3(repeating: 0.32), color: Vec4(1, 0.9, 0.6, 1), mat: .glow(3))
        }
        for x in [-14, 14] as [Float] {
            b.box(Vec3(logo.x + x - 0.4, 0, logo.z + 0.5), Vec3(logo.x + x + 0.4, logo.y - 4.4, logo.z + 1.3), color: Vec4(0.2, 0.2, 0.22, 1), mat: steel)
        }
        lights.append((logo + Vec3(0, 0, -10), Vec3(1, 0.85, 0.55), 14, 40))
    }

    // MARK: Render

    /// Draws the ride at `time` seconds. Returns the screen texture.
    func render(_ cmd: MTLCommandBuffer, time: Double, stereo: Bool) -> MTLTexture? {
        if color == nil {
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            cd.usage = [.renderTarget, .shaderRead]
            cd.storageMode = .private
            color = device.makeTexture(descriptor: cd)
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            dd.usage = .renderTarget
            dd.storageMode = .private
            depth = device.makeTexture(descriptor: dd)
            average.contents().bindMemory(to: Vec4.self, capacity: 65).initialize(repeating: .zero, count: 65)
        }
        guard let color, let depth else { return nil }
        let pose = track.pose(at: time)
        let look = track.tangent(at: pose.distance + 3)
        let f = track.frame(atDistance: pose.distance)
        let eye = pose.position + pose.up * 1.25
        let dir = simd_normalize(f.forward * 0.6 + look * 0.4)
        let passes: [(MTLRenderPipelineState, Float, Bool)] = stereo ? [(leftEye, -0.032, true), (rightEye, 0.032, false)] : [(mono, 0, true)]
        for (pipeline, offset, clearColor) in passes {
            let e = eye + f.right * offset
            let proj = Mat4.perspective(fovyRadians: 1.2, aspect: Float(width) / Float(height), near: 0.1, far: 400)
            let view = Mat4.lookAt(eye: e, target: e + dir * 10, up: pose.up)
            var frame = FrameUniforms(viewProj: proj * view, cameraPos: Vec4(e.x, e.y, e.z, Float(time)),
                                      ambient: Vec4(0.07, 0.065, 0.1, 0), fog: Vec4(0.03, 0.025, 0.06, 0.004),
                                      screenCenter: .zero, screenNormal: .zero, screenRight: .zero, screenUp: .zero,
                                      lightInfo: Vec4(0, 1.15, 0, 0))
            var near = lights.sorted { simd_distance($0.0, e) < simd_distance($1.0, e) }.prefix(16).flatMap { l in
                [Vec4(l.0.x, l.0.y, l.0.z, l.3), Vec4(l.1.x, l.1.y, l.1.z, l.2)]
            }
            frame.lightInfo.x = Float(near.count / 2)
            if near.isEmpty { near = [.zero, .zero] }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = clearColor ? .clear : .load
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.01, green: 0.01, blue: 0.03, alpha: 1)
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.none)
            enc.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            enc.setFragmentBuffer(average, offset: 0, index: 3)
            near.withUnsafeBytes { raw in enc.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 4) }
            for b in batches {
                var u = DrawUniforms(model: matrix_identity_float4x4, baseColor: Vec4(1, 1, 1, 1),
                                     emissive: Vec4(0, 0, 0, b.key.emissive),
                                     params: Vec4(b.key.roughness, b.key.metallic, Float(b.key.mode), b.key.texture == nil ? 0 : 1))
                enc.setVertexBuffer(b.buffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentTexture(b.key.texture.flatMap { textures[$0] } ?? white, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: b.count)
            }
            drawDynamic(enc, time: time, pose: pose, frame: f, eye: eye)
            enc.endEncoding()
        }
        return color
    }

    private func drawCube(_ enc: MTLRenderCommandEncoder, model: simd_float4x4, color: Vec4, emissive: Float = 0, rough: Float = 0.5, metal: Float = 0) {
        var u = DrawUniforms(model: model, baseColor: color, emissive: Vec4(0, 0, 0, emissive),
                             params: Vec4(rough, metal, Float(emissive > 0 ? ShadingMode.emissive.rawValue : ShadingMode.lit.rawValue), 0))
        enc.setVertexBuffer(cube, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setFragmentTexture(white, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cubeCount)
    }

    private func basis(_ p: Vec3, _ x: Vec3, _ y: Vec3, _ z: Vec3, _ size: Vec3) -> simd_float4x4 {
        simd_float4x4(columns: (Vec4(x * size.x, 0), Vec4(y * size.y, 0), Vec4(z * size.z, 0), Vec4(p, 1)))
    }

    private func drawDynamic(_ enc: MTLRenderCommandEncoder, time: Double, pose: ZMFCoasterTrack.Pose,
                             frame f: (forward: Vec3, right: Vec3, up: Vec3), eye: Vec3) {
        // Your car: red nose, gold trim and the padded lap bar in front of you.
        let car = pose.position + pose.up * 0.45
        drawCube(enc, model: basis(car + f.forward * 1.3, f.right, pose.up, f.forward, Vec3(1.5, 0.5, 1.2)), color: Vec4(0.7, 0.03, 0.06, 1), rough: 0.25, metal: 0.5)
        drawCube(enc, model: basis(car + f.forward * 1.95 + pose.up * 0.2, f.right, pose.up, f.forward, Vec3(1.55, 0.08, 0.1)), color: Vec4(1, 0.8, 0.35, 1), emissive: 1.5)
        drawCube(enc, model: basis(eye + f.forward * 0.55 - pose.up * 0.42, f.right, pose.up, f.forward, Vec3(0.9, 0.12, 0.14)), color: Vec4(0.08, 0.08, 0.09, 1), rough: 0.8)
        for side in [-0.38, 0.38] as [Float] {
            drawCube(enc, model: basis(eye + f.forward * 0.5 - pose.up * 0.62 + f.right * side, f.right, pose.up, f.forward, Vec3(0.06, 0.36, 0.06)),
                     color: Vec4(0.75, 0.76, 0.8, 1), rough: 0.2, metal: 0.9)
        }
        // Spray kicked up through the splash tunnel.
        if pose.inSplash {
            for i in 0..<60 {
                let fi = Float(i)
                let life = Float((time * 1.6 + Double(hash(fi))).truncatingRemainder(dividingBy: 1))
                let side = (hash(fi + 3) - 0.5) * 4
                let p = pose.position + f.forward * (2 + hash(fi + 1) * 6 - life * 3) + f.right * side +
                    Vec3(0, 0.3 + sinf(life * .pi) * (1.5 + hash(fi + 5) * 2), 0)
                drawCube(enc, model: Mat4.translation(p) * Mat4.scale(Vec3(repeating: 0.06 + hash(fi + 2) * 0.08)), color: Vec4(0.75, 0.9, 1, 1), emissive: 1.2)
            }
        }
        // Fireworks over the marquee for the finale.
        let finaleStart = Double(track.rideDuration) - 9
        if time > finaleStart {
            let logo = ZMFCoasterTrack.logoPosition
            for burst in 0..<5 {
                let start = finaleStart + Double(burst) * 1.7
                let age = Float(time - start)
                guard age > 0, age < 2.6 else { continue }
                let centre = logo + Vec3((hash(Float(burst)) - 0.5) * 40, 12 + hash(Float(burst) + 4) * 10, 6 + hash(Float(burst) + 8) * 8)
                let hue = [Vec4(1, 0.75, 0.3, 1), Vec4(1, 0.2, 0.25, 1), Vec4(0.4, 0.8, 1, 1), Vec4(1, 0.95, 0.8, 1), Vec4(0.8, 0.4, 1, 1)][burst]
                for k in 0..<36 {
                    let a = hash(Float(burst * 50 + k)) * 2 * .pi, e = (hash(Float(burst * 50 + k) + 1) - 0.5) * .pi
                    let dir = Vec3(cosf(a) * cosf(e), sinf(e), sinf(a) * cosf(e))
                    let p = centre + dir * age * 7 - Vec3(0, age * age * 1.2, 0)
                    drawCube(enc, model: Mat4.translation(p) * Mat4.scale(Vec3(repeating: 0.35 * max(0.2, 1 - age / 2.6))),
                             color: hue, emissive: 4 * max(0, 1 - age / 2.6))
                }
            }
        }
    }
}
