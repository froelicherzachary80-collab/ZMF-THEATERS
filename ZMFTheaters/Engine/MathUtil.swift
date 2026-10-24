import simd

typealias Vec2 = SIMD2<Float>
typealias Vec3 = SIMD3<Float>
typealias Vec4 = SIMD4<Float>

enum Mat4 {
    static func perspective(fovyRadians fovy: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys = 1 / tanf(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return simd_float4x4(columns: (
            Vec4(xs, 0, 0, 0),
            Vec4(0, ys, 0, 0),
            Vec4(0, 0, zs, -1),
            Vec4(0, 0, zs * near, 0)
        ))
    }

    static func lookAt(eye: Vec3, target: Vec3, up: Vec3) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(columns: (
            Vec4(s.x, u.x, -f.x, 0),
            Vec4(s.y, u.y, -f.y, 0),
            Vec4(s.z, u.z, -f.z, 0),
            Vec4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    static func translation(_ t: Vec3) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = Vec4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: Vec3) -> simd_float4x4 {
        simd_float4x4(diagonal: Vec4(s.x, s.y, s.z, 1))
    }

    static func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cosf(a), s = sinf(a)
        return simd_float4x4(columns: (
            Vec4(c, 0, -s, 0),
            Vec4(0, 1, 0, 0),
            Vec4(s, 0, c, 0),
            Vec4(0, 0, 0, 1)
        ))
    }
}

/// Forward direction for a yaw angle: yaw 0 looks down +Z (from the lobby toward the auditorium hall).
@inline(__always) func forwardVector(yaw: Float, pitch: Float = 0) -> Vec3 {
    Vec3(sinf(yaw) * cosf(pitch), sinf(pitch), cosf(yaw) * cosf(pitch))
}

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

@inline(__always) func wrapAngle(_ a: Float) -> Float {
    var x = a
    while x > .pi { x -= 2 * .pi }
    while x < -.pi { x += 2 * .pi }
    return x
}
