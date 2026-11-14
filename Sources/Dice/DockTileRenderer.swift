import AppKit

/// Owns the Dock tile's content view and swaps between the die face and the empty slot.
final class DockTileRenderer {
    private let imageView: NSImageView
    private var current = ""

    init() {
        let tile = NSApp.dockTile
        imageView = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        tile.contentView = imageView
    }

    func showFace(_ value: Int, palette: DiePalette = .classic) {
        let key = "face\(value)-\(palette.name)"
        guard key != current else { return }
        current = key
        let img = DieArt.tileFace(value: value, px: 256, palette: palette)
        set(img)
        dlog("TILE shows die face \(value) (\(palette.name))")
        saveDebugCopy(img, name: "tile-face\(value)-\(palette.name)")
    }

    /// DICE_SNAPSHOT_DIR: keep a PNG of each tile image set, so the tile can be checked without a screenshot.
    private func saveDebugCopy(_ img: CGImage, name: String) {
        guard let dir = env["DICE_SNAPSHOT_DIR"] else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? png.write(to: url)
        dlog("SNAPSHOT \(url.path) (tile image)")
    }

    func showEmptySlot() {
        guard current != "empty" else { return }
        current = "empty"
        set(DieArt.emptySlot(px: 256))
        dlog("TILE shows empty slot")
    }

    /// Hot Hand banked total as the Dock badge; hidden at zero.
    func setBadge(_ value: Int) {
        let label: String? = value > 0 ? "\(value)" : nil
        guard NSApp.dockTile.badgeLabel != label else { return }
        NSApp.dockTile.badgeLabel = label
        NSApp.dockTile.display()
        dlog("TILE badge -> \(label ?? "none")")
    }

    private func set(_ image: CGImage) {
        let tile = NSApp.dockTile
        imageView.frame = NSRect(origin: .zero, size: tile.size)
        imageView.image = NSImage(cgImage: image, size: tile.size)
        tile.display()
    }
}
