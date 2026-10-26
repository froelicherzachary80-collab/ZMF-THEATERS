import SwiftUI
import simd

/// Projects the physical auditorium screen to the iPhone viewport, so an
/// official, interactive WKWebView stays aligned to the movie screen instead
/// of floating as a separate 2D player panel.
///
/// The WebKit view is composited above the Metal layer. This is intentional:
/// third-party streaming frames cannot be copied into our Metal texture.
@MainActor
enum CinemaScreenProjection {
    static func projectedRect(game: CinemaGame, viewport: CGSize,
                              verticalFOV: Float = 55) -> CGRect? {
        guard let seating = game.seatedAt,
              viewport.width > 10, viewport.height > 10 else { return nil }
        return projectedRect(room: seating.room, camera: game.camera(),
                             viewport: viewport, verticalFOV: verticalFOV)
    }

    static func projectedRect(room: Int, camera: CinemaGame.CameraState,
                              viewport: CGSize, verticalFOV: Float) -> CGRect? {
        guard (1...12).contains(room), viewport.width > 10, viewport.height > 10 else { return nil }
        let direction = camera.target - camera.eye
        guard simd_length_squared(direction) > 0.0001 else { return nil }
        let centre = CinemaWorld.screenCenter(room)
        let normal = CinemaWorld.screenNormal(room)
        // World-space right points toward the spectator's right in both wings.
        let right = simd_normalize(simd_cross(Vec3(0, 1, 0), normal))
        let up = Vec3(0, 1, 0)
        // Slight inset hides the curved-screen frame's edge artifacts and
        // prevents WebKit's square corners spilling into the black masking.
        let halfW = CinemaWorld.screenSize.x * 0.482
        let halfH = CinemaWorld.screenSize.y * 0.482
        let points = [
            centre - right * halfW + up * halfH,
            centre + right * halfW + up * halfH,
            centre + right * halfW - up * halfH,
            centre - right * halfW - up * halfH
        ]
        let fov = max(30, min(75, verticalFOV)) * .pi / 180
        let proj = Mat4.perspective(fovyRadians: fov,
                                    aspect: Float(viewport.width / viewport.height),
                                    near: 0.05, far: 160)
        let view = Mat4.lookAt(eye: camera.eye, target: camera.target, up: up)
        let vp = proj * view
        var screenPoints: [CGPoint] = []
        for point in points {
            let clip = vp * Vec4(point.x, point.y, point.z, 1)
            guard clip.w > 0.05, clip.x.isFinite, clip.y.isFinite else { return nil }
            let xx = CGFloat(clip.x / clip.w), yy = CGFloat(clip.y / clip.w)
            guard xx.isFinite, yy.isFinite else { return nil }
            screenPoints.append(CGPoint(
                x: (xx * 0.5 + 0.5) * viewport.width,
                y: (0.5 - yy * 0.5) * viewport.height
            ))
        }
        guard let minX = screenPoints.map(\.x).min(),
              let maxX = screenPoints.map(\.x).max(),
              let minY = screenPoints.map(\.y).min(),
              let maxY = screenPoints.map(\.y).max() else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard rect.width > 20, rect.height > 20,
              rect.width < viewport.width * 4,
              rect.height < viewport.height * 4 else { return nil }
        // Don't allow a video portal when turned away from the movie screen.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard center.x > -viewport.width * 0.6,
              center.x < viewport.width * 1.6,
              center.y > -viewport.height * 0.6,
              center.y < viewport.height * 1.6 else { return nil }
        return rect
    }
}
