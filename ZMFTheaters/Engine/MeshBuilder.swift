import simd

/// Interleaved vertex. Layout must match `VertexIn` in Shaders.metal (48 bytes).
struct Vertex {
    var px: Float, py: Float, pz: Float
    var nx: Float, ny: Float, nz: Float
    var u: Float, v: Float
    var r: Float, g: Float, b: Float, a: Float

    init(_ p: Vec3, _ n: Vec3, _ uv: Vec2, _ c: Vec4) {
        px = p.x; py = p.y; pz = p.z
        nx = n.x; ny = n.y; nz = n.z
        u = uv.x; v = uv.y
        r = c.x; g = c.y; b = c.z; a = c.w
    }
}

enum ShadingMode: Int {
    case lit = 0, litTextured = 1, screen = 2, emissive = 3, carpet = 4, glossyFloor = 5, emissiveTextured = 6
}

/// Groups geometry into draw batches. Static geometry sharing a material is
/// merged into a single vertex buffer (static batching).
struct MaterialKey: Hashable {
    var mode: Int
    var texture: String?
    var roughness: Float
    var metallic: Float
    var emissive: Float

    static func lit(rough: Float = 0.7, metal: Float = 0) -> MaterialKey { MaterialKey(mode: ShadingMode.lit.rawValue, texture: nil, roughness: rough, metallic: metal, emissive: 0) }
    static func textured(_ tex: String, rough: Float = 0.6) -> MaterialKey { MaterialKey(mode: ShadingMode.litTextured.rawValue, texture: tex, roughness: rough, metallic: 0, emissive: 0) }
    static func glow(_ strength: Float) -> MaterialKey { MaterialKey(mode: ShadingMode.emissive.rawValue, texture: nil, roughness: 1, metallic: 0, emissive: strength) }
    static func glowTex(_ tex: String, _ strength: Float) -> MaterialKey { MaterialKey(mode: ShadingMode.emissiveTextured.rawValue, texture: tex, roughness: 1, metallic: 0, emissive: strength) }
    static func screen(_ tex: String) -> MaterialKey { MaterialKey(mode: ShadingMode.screen.rawValue, texture: tex, roughness: 1, metallic: 0, emissive: 1) }
    static let carpet = MaterialKey(mode: ShadingMode.carpet.rawValue, texture: nil, roughness: 0.95, metallic: 0, emissive: 0)
    static let glossy = MaterialKey(mode: ShadingMode.glossyFloor.rawValue, texture: nil, roughness: 0.18, metallic: 0, emissive: 0)
}

/// Maps auditorium-local coordinates to world space. East-wing rooms are
/// mirrored on X, so normals are mirrored too.
struct RoomTransform {
    var originX: Float
    var signX: Float
    var originZ: Float

    static let identity = RoomTransform(originX: 0, signX: 1, originZ: 0)

    func point(_ p: Vec3) -> Vec3 { Vec3(originX + signX * p.x, p.y, originZ + p.z) }
    func normal(_ n: Vec3) -> Vec3 { Vec3(signX * n.x, n.y, n.z) }
}

final class MeshBuilder {
    private(set) var batches: [MaterialKey: [Vertex]] = [:]
    var xf = RoomTransform.identity

    var vertexCount: Int { batches.values.reduce(0) { $0 + $1.count } }

    /// Quad from four local-space corners (counter-clockwise when viewed from the front).
    func quad(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3, normal n: Vec3, color: Vec4, mat: MaterialKey,
              uv: (Vec2, Vec2, Vec2, Vec2) = (Vec2(0, 1), Vec2(1, 1), Vec2(1, 0), Vec2(0, 0))) {
        let pa = xf.point(a), pb = xf.point(b), pc = xf.point(c), pd = xf.point(d)
        let wn = xf.normal(n)
        appendWorldQuad(pa, pb, pc, pd, wn, color, mat, uv)
    }

    private func appendWorldQuad(_ pa: Vec3, _ pb: Vec3, _ pc: Vec3, _ pd: Vec3, _ n: Vec3, _ color: Vec4, _ mat: MaterialKey,
                                 _ uv: (Vec2, Vec2, Vec2, Vec2)) {
        var list = batches[mat] ?? []
        list.append(Vertex(pa, n, uv.0, color))
        list.append(Vertex(pb, n, uv.1, color))
        list.append(Vertex(pc, n, uv.2, color))
        list.append(Vertex(pa, n, uv.0, color))
        list.append(Vertex(pc, n, uv.2, color))
        list.append(Vertex(pd, n, uv.3, color))
        batches[mat] = list
    }

    /// Axis-aligned box in local space with outward normals.
    func box(_ mn: Vec3, _ mx: Vec3, color: Vec4, mat: MaterialKey = .lit()) {
        let p000 = Vec3(mn.x, mn.y, mn.z), p100 = Vec3(mx.x, mn.y, mn.z)
        let p010 = Vec3(mn.x, mx.y, mn.z), p110 = Vec3(mx.x, mx.y, mn.z)
        let p001 = Vec3(mn.x, mn.y, mx.z), p101 = Vec3(mx.x, mn.y, mx.z)
        let p011 = Vec3(mn.x, mx.y, mx.z), p111 = Vec3(mx.x, mx.y, mx.z)
        quad(p001, p101, p111, p011, normal: Vec3(0, 0, 1), color: color, mat: mat)   // +Z
        quad(p100, p000, p010, p110, normal: Vec3(0, 0, -1), color: color, mat: mat)  // -Z
        quad(p101, p100, p110, p111, normal: Vec3(1, 0, 0), color: color, mat: mat)   // +X
        quad(p000, p001, p011, p010, normal: Vec3(-1, 0, 0), color: color, mat: mat)  // -X
        quad(p011, p111, p110, p010, normal: Vec3(0, 1, 0), color: color, mat: mat)   // +Y
        quad(p000, p100, p101, p001, normal: Vec3(0, -1, 0), color: color, mat: mat)  // -Y
    }

    func box(center c: Vec3, size s: Vec3, color: Vec4, mat: MaterialKey = .lit()) {
        box(c - s * 0.5, c + s * 0.5, color: color, mat: mat)
    }

    /// A camera-readable rectangle (sign, poster, screen). Built in world space
    /// after transforming centre and normal, so text is never mirrored.
    func sign(center: Vec3, normal: Vec3, width: Float, height: Float, color: Vec4 = Vec4(1, 1, 1, 1), mat: MaterialKey) {
        let wc = xf.point(center)
        let wn = simd_normalize(xf.normal(normal))
        let up = Vec3(0, 1, 0)
        let right = simd_normalize(simd_cross(-wn, up))
        let hw = right * (width * 0.5), hh = up * (height * 0.5)
        let offset = wn * 0.01
        appendWorldQuad(wc - hw - hh + offset, wc + hw - hh + offset, wc + hw + hh + offset, wc - hw + hh + offset, wn, color, mat,
                        (Vec2(0, 1), Vec2(1, 1), Vec2(1, 0), Vec2(0, 0)))
    }

    /// Horizontal floor/ceiling rectangle. `up` selects the facing.
    func flat(x0: Float, x1: Float, z0: Float, z1: Float, y: Float, up: Bool, color: Vec4, mat: MaterialKey) {
        let n = Vec3(0, up ? 1 : -1, 0)
        let uvs = (Vec2(x0, z0) * 0.5, Vec2(x1, z0) * 0.5, Vec2(x1, z1) * 0.5, Vec2(x0, z1) * 0.5)
        quad(Vec3(x0, y, z0), Vec3(x1, y, z0), Vec3(x1, y, z1), Vec3(x0, y, z1), normal: n, color: color, mat: mat, uv: uvs)
    }

    /// Wall in the plane x = const spanning z0..z1, y0..y1, facing ±X.
    func wallX(x: Float, z0: Float, z1: Float, y0: Float, y1: Float, facingPositive: Bool, color: Vec4, mat: MaterialKey = .lit(rough: 0.85)) {
        let n = Vec3(facingPositive ? 1 : -1, 0, 0)
        quad(Vec3(x, y0, z0), Vec3(x, y0, z1), Vec3(x, y1, z1), Vec3(x, y1, z0), normal: n, color: color, mat: mat)
    }

    /// Wall in the plane z = const spanning x0..x1, y0..y1, facing ±Z.
    func wallZ(z: Float, x0: Float, x1: Float, y0: Float, y1: Float, facingPositive: Bool, color: Vec4, mat: MaterialKey = .lit(rough: 0.85)) {
        let n = Vec3(0, 0, facingPositive ? 1 : -1)
        quad(Vec3(x0, y0, z), Vec3(x1, y0, z), Vec3(x1, y1, z), Vec3(x0, y1, z), normal: n, color: color, mat: mat)
    }
}

@inline(__always) func rgb(_ c: Vec3, _ k: Float = 1) -> Vec4 { Vec4(c.x * k, c.y * k, c.z * k, 1) }
@inline(__always) func rgb(_ r: Float, _ g: Float, _ b: Float) -> Vec4 { Vec4(r, g, b, 1) }
