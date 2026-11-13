// Renders AppIcon.iconset with DieArt (compiled together with Sources/Dice/DieArt.swift by
// scripts/build-app.sh) and packs it with iconutil.
//   make-icon <out.iconset> <out.icns>
import CoreGraphics
import Foundation
import ImageIO

@main
struct MakeIcon {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write("usage: make-icon <out.iconset> <out.icns>\n".data(using: .utf8)!)
            exit(2)
        }
        let iconset = URL(fileURLWithPath: args[1])
        let icns = URL(fileURLWithPath: args[2])
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        let entries: [(String, Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, px) in entries {
            let image = DieArt.tileFace(value: 5, px: px)
            let url = iconset.appendingPathComponent("icon_\(name).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                throw NSError(domain: "make-icon", code: 1)
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "make-icon", code: 2) }
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            FileHandle.standardError.write("iconutil failed (\(p.terminationStatus))\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
