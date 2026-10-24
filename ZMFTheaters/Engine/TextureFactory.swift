import UIKit
import Metal
import MetalKit

/// Draws signage, posters and preshow slides with Core Graphics and uploads
/// them as sRGB, mip-mapped Metal textures.
@MainActor
final class TextureFactory {
    let device: MTLDevice
    private let loader: MTKTextureLoader

    init(device: MTLDevice) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
    }

    func texture(from image: UIImage) -> MTLTexture? {
        guard let cg = image.cgImage else { return nil }
        return try? loader.newTexture(cgImage: cg, options: [
            .SRGB: true,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
    }

    func render(size: CGSize, _ draw: (CGContext, CGRect) -> Void) -> MTLTexture? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(ctx.cgContext, CGRect(origin: .zero, size: size))
        }
        return texture(from: img)
    }

    static func drawCentered(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, shadow: UIColor? = nil) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        if let shadow {
            let s = NSShadow()
            s.shadowColor = shadow
            s.shadowBlurRadius = 12
            attrs[.shadow] = s
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let h = str.boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).height
        str.draw(with: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h), options: [.usesLineFragmentOrigin], context: nil)
    }

    static func color(_ v: Vec3, _ k: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat(v.x) * k, green: CGFloat(v.y) * k, blue: CGFloat(v.z) * k, alpha: 1)
    }

    // MARK: Static signage

    func label(_ text: String, size: CGSize, font: UIFont, fg: UIColor, bg: UIColor, border: UIColor? = nil) -> MTLTexture? {
        render(size: size) { ctx, r in
            bg.setFill(); ctx.fill(r)
            if let border {
                border.setStroke()
                ctx.setLineWidth(size.height * 0.06)
                ctx.stroke(r.insetBy(dx: size.height * 0.05, dy: size.height * 0.05))
            }
            Self.drawCentered(text, in: r.insetBy(dx: 8, dy: 4), font: font, color: fg, shadow: fg.withAlphaComponent(0.8))
        }
    }

    func marquee() -> MTLTexture? {
        render(size: CGSize(width: 1100, height: 240)) { ctx, r in
            UIColor(red: 0.12, green: 0.02, blue: 0.05, alpha: 1).setFill(); ctx.fill(r)
            UIColor(red: 1, green: 0.84, blue: 0.5, alpha: 1).setFill()
            var x: CGFloat = 20
            while x < r.width - 10 {
                ctx.fillEllipse(in: CGRect(x: x, y: 10, width: 14, height: 14))
                ctx.fillEllipse(in: CGRect(x: x, y: r.height - 24, width: 14, height: 14))
                x += 36
            }
            Self.drawCentered("ZMF THEATERS+", in: r.insetBy(dx: 20, dy: 30), font: .systemFont(ofSize: 100, weight: .black),
                              color: UIColor(red: 1, green: 0.8, blue: 0.3, alpha: 1), shadow: .orange)
        }
    }

    func menuBoard(_ s: AppSettings) -> MTLTexture? {
        render(size: CGSize(width: 1040, height: 360)) { ctx, r in
            UIColor(white: 0.05, alpha: 1).setFill(); ctx.fill(r)
            let items = [("POPCORN", s.popcornPrice), ("SODA", s.sodaPrice), ("CANDY", s.candyPrice), ("SLUSHIE", s.sodaPrice + 5), ("NACHOS", s.popcornPrice + 5), ("ICE CREAM", s.candyPrice + 10)]
            for (i, item) in items.enumerated() {
                let col = CGFloat(i % 2), row = CGFloat(i / 2)
                let cell = CGRect(x: 20 + col * 510, y: 20 + row * 110, width: 490, height: 100)
                UIColor(red: 0.25, green: 0.05, blue: 0.08, alpha: 1).setFill()
                ctx.fill(cell)
                Self.drawCentered("\(item.0)  Z$\(item.1)", in: cell, font: .systemFont(ofSize: 50, weight: .heavy), color: .white)
            }
        }
    }

    // MARK: Dynamic signage

    func doorSign(room: CinemaRoom, film: String?) -> MTLTexture? {
        render(size: CGSize(width: 768, height: 260)) { ctx, r in
            Self.color(room.theme.wall, 0.6).setFill(); ctx.fill(r)
            Self.color(room.theme.accent).setStroke()
            ctx.setLineWidth(10); ctx.stroke(r.insetBy(dx: 8, dy: 8))
            Self.drawCentered("\(room.code)  \(room.name.uppercased())\(room.is3D ? "  3D" : "")",
                              in: CGRect(x: 20, y: 20, width: r.width - 40, height: 120), font: .systemFont(ofSize: 54, weight: .black), color: Self.color(room.theme.accent), shadow: .black)
            Self.drawCentered(film ?? "Private screenings available", in: CGRect(x: 20, y: 140, width: r.width - 40, height: 100),
                              font: .systemFont(ofSize: 40, weight: .semibold), color: .white)
        }
    }

    func poster(image: UIImage?, title: String, room: CinemaRoom) -> MTLTexture? {
        render(size: CGSize(width: 400, height: 600)) { ctx, r in
            if let image {
                image.draw(in: r)
            } else {
                let colors = [Self.color(room.theme.accent).cgColor, Self.color(room.theme.wall, 0.4).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: r.height), options: [])
                }
                Self.drawCentered(title.uppercased(), in: r.insetBy(dx: 24, dy: 120), font: .systemFont(ofSize: 44, weight: .black), color: .white, shadow: .black)
                Self.drawCentered("ROOM \(room.code)", in: CGRect(x: 0, y: r.height - 90, width: r.width, height: 60), font: .systemFont(ofSize: 30, weight: .bold), color: .white)
            }
        }
    }

    /// Idle screen shown in rooms where no screening is running: real preview signage
    /// built from the featured film's backdrop, title and next showtime.
    func idleScreen(room: CinemaRoom, title: String?, backdrop: UIImage?, next: String?) -> MTLTexture? {
        render(size: CGSize(width: 1200, height: 520)) { ctx, r in
            UIColor.black.setFill(); ctx.fill(r)
            if let backdrop {
                backdrop.draw(in: r, blendMode: .normal, alpha: 0.45)
            }
            Self.drawCentered("ROOM \(room.code) · \(room.name.uppercased())", in: CGRect(x: 0, y: 60, width: r.width, height: 80),
                              font: .systemFont(ofSize: 48, weight: .heavy), color: Self.color(room.theme.accent), shadow: .black)
            Self.drawCentered(title ?? "Choose any film from your library for a private screening", in: CGRect(x: 60, y: 170, width: r.width - 120, height: 180),
                              font: .systemFont(ofSize: title == nil ? 40 : 76, weight: .black), color: .white, shadow: .black)
            if let next {
                Self.drawCentered(next, in: CGRect(x: 0, y: 380, width: r.width, height: 70), font: .systemFont(ofSize: 38, weight: .semibold), color: UIColor(white: 0.85, alpha: 1))
            }
        }
    }

    /// Full-screen preshow slide (welcome card, reminders, countdown).
    func slide(lines: [String], accent: Vec3, highlight: Int = 1) -> MTLTexture? {
        render(size: CGSize(width: 1200, height: 520)) { ctx, r in
            let colors = [UIColor(white: 0.02, alpha: 1).cgColor, Self.color(accent, 0.35).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: r.width, y: r.height), options: [])
            }
            let n = max(1, lines.count)
            let lineH = r.height / CGFloat(n + 1)
            for (i, line) in lines.enumerated() {
                let big = i == highlight
                Self.drawCentered(line, in: CGRect(x: 40, y: lineH * CGFloat(i) + lineH * 0.5, width: r.width - 80, height: lineH),
                                  font: .systemFont(ofSize: big ? 84 : 40, weight: big ? .black : .semibold),
                                  color: big ? Self.color(accent) : .white, shadow: big ? .black : nil)
            }
        }
    }

    /// One frame of the animated ZMF THEATERS+ ident: a sweeping light beam behind the logo.
    func ident(phase: Double) -> MTLTexture? {
        render(size: CGSize(width: 1200, height: 520)) { ctx, r in
            UIColor.black.setFill(); ctx.fill(r)
            let cx = r.width * CGFloat(0.5 + 0.45 * sin(phase * 1.3))
            let colors = [UIColor(red: 1, green: 0.75, blue: 0.3, alpha: 0.85).cgColor, UIColor.clear.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: r.height * 0.5), startRadius: 0,
                                       endCenter: CGPoint(x: cx, y: r.height * 0.5), endRadius: r.width * 0.45, options: [])
            }
            let glow = CGFloat(0.6 + 0.4 * sin(phase * 3))
            Self.drawCentered("ZMF", in: CGRect(x: 0, y: 90, width: r.width, height: 240), font: .systemFont(ofSize: 220, weight: .black),
                              color: UIColor(red: 1, green: 0.8 * glow + 0.2, blue: 0.3, alpha: 1), shadow: .orange)
            Self.drawCentered("THEATERS+  ·  PRIVATE CINEMA UNIVERSE", in: CGRect(x: 0, y: 340, width: r.width, height: 80),
                              font: .systemFont(ofSize: 44, weight: .heavy), color: .white)
        }
    }

    func solid(_ c: Vec4) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        var px: [UInt8] = [UInt8(c.x * 255), UInt8(c.y * 255), UInt8(c.z * 255), UInt8(c.w * 255)]
        t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return t
    }
}
