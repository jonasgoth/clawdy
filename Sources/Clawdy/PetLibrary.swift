import AppKit
import SpriteKit
import CoreImage

/// The Clawd pets: pre-baked frame sheets in Resources/pets (see tools/render-pets.py), one per
/// crab state. Frames are sliced from the sheet once, hue-rotated per project color, and cached.
enum PetLibrary {
    struct Sheet { let file: String; let frames: Int }

    static let baseHueDegrees: CGFloat = 14     // the pets' own orange

    private static var cell: CGFloat = 240
    private static var cols = 8
    private static var rows = 4
    private(set) static var fps: Double = 8
    private static var sheets: [String: Sheet] = [:]
    /// The "working:<pet>" keys, in rotation order — one working animation per session.
    private static var workingKeys: [String] = []
    private static var sourceImages: [String: CGImage] = [:]
    private static var frameCache: [String: [SKTexture]] = [:]
    private static var loaded = false

    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("pets") }

    /// True once the manifest and sheets are found in the app bundle.
    static var isAvailable: Bool { load(); return !sheets.isEmpty }

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = obj["states"] as? [String: [String: Any]] else { return }
        workingKeys = (obj["workingVariants"] as? [String]) ?? []
        cell = CGFloat((obj["cell"] as? Double) ?? 240)
        cols = (obj["cols"] as? Int) ?? 8
        rows = (obj["rows"] as? Int) ?? 4
        fps = (obj["fps"] as? Double) ?? 8
        for (state, info) in states {
            guard let file = info["file"] as? String, let frames = info["frames"] as? Int else { continue }
            sheets[state] = Sheet(file: file, frames: frames)
        }
    }

    /// The working animation this session keeps for life: a stable pick from the rotation,
    /// so every crab has its own working personality but always the same one.
    static func workingKey(for id: String) -> String {
        load()
        guard !workingKeys.isEmpty else { return "working" }
        var hash: UInt64 = 7919
        for byte in id.utf8 { hash = (hash &* 131) &+ UInt64(byte) }
        return workingKeys[Int(hash % UInt64(workingKeys.count))]
    }

    /// Animation frames for a state key ("working", "moving", …) tinted to the given hue.
    /// Falls back to the un-tinted sheet, then to an empty array if the state is unknown.
    static func frames(_ state: String, hueDegrees: CGFloat) -> [SKTexture] {
        load()
        let key = "\(state)@\(Int(hueDegrees.rounded()))"
        if let cached = frameCache[key] { return cached }
        guard let sheet = sheets[state], let source = sourceImage(for: sheet) else { return [] }

        let rotation = (hueDegrees - baseHueDegrees) * .pi / 180
        let image = abs(rotation) < 0.001 ? source : (hueRotated(source, byRadians: rotation) ?? source)
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest

        let w = 1.0 / CGFloat(cols), h = 1.0 / CGFloat(rows)
        var out: [SKTexture] = []
        for i in 0..<sheet.frames {
            let col = i % cols, row = i / cols
            // SpriteKit texture rects have their origin at the bottom-left.
            let rect = CGRect(x: CGFloat(col) * w, y: 1 - CGFloat(row + 1) * h, width: w, height: h)
            let t = SKTexture(rect: rect, in: texture)
            t.filteringMode = .nearest
            out.append(t)
        }
        frameCache[key] = out
        return out
    }

    private static func sourceImage(for sheet: Sheet) -> CGImage? {
        if let cached = sourceImages[sheet.file] { return cached }
        guard let dir = directory,
              let image = NSImage(contentsOf: dir.appendingPathComponent(sheet.file)),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return nil }
        sourceImages[sheet.file] = cg
        return cg
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func hueRotated(_ image: CGImage, byRadians angle: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIHueAdjust") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: Double(angle)), forKey: kCIInputAngleKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent)
    }
}
