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
        set(DieArt.tileFace(value: value, px: 256, palette: palette))
        dlog("TILE shows die face \(value) (\(palette.name))")
    }

    func showEmptySlot() {
        guard current != "empty" else { return }
        current = "empty"
        set(DieArt.emptySlot(px: 256))
        dlog("TILE shows empty slot")
    }

    private func set(_ image: CGImage) {
        let tile = NSApp.dockTile
        imageView.frame = NSRect(origin: .zero, size: tile.size)
        imageView.image = NSImage(cgImage: image, size: tile.size)
        tile.display()
    }
}
