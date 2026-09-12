import AppKit
import SpriteKit
import ImageIO

/// The Clawd pets: pre-baked frame sheets in Resources/pets (see tools/render-pets.py), one per
/// crab state. Frames are sliced from the sheet once and shared by every crab. Each crab's project
/// colour is applied on the GPU by `hueShader`, so there is one texture per state, not one per colour.
enum PetLibrary {
    struct Sheet { let file: String; let frames: Int }

    static let baseHueDegrees: CGFloat = 14     // the pets' own orange

    private static var cell: CGFloat = 240
    private static var cols = 8
    private static var rows = 4
    private(set) static var fps: Double = 8
    private static var sheets: [String: Sheet] = [:]
    /// The "working:<pet>" keys to draw from — one working animation per session.
    private static var workingKeys: [String] = []
    /// Which working animation each session drew, remembered on disk so a crab keeps its own
    /// personality across restarts.
    private static let workingPickDefaultsKey = "workingPetBySession"
    private static var workingPicks: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "workingPetBySession") as? [String: String]) ?? [:]
    private static var frameCache: [String: [SKTexture]] = [:]
    private static var loaded = false

    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("pets") }

    /// True once the manifest and sheets are found in the app bundle.
    static var isAvailable: Bool { load(); return !sheets.isEmpty }

    private static let debug = ProcessInfo.processInfo.environment["CLAWDY_DEBUG"] == "1"

    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let states = obj["states"] as? [String: [String: Any]] else {
            if debug { FileHandle.standardError.write(Data("[pets] no manifest at \(directory?.path ?? "nil")\n".utf8)) }
            return
        }
        if debug { FileHandle.standardError.write(Data("[pets] \(states.count) states from \(dir.path)\n".utf8)) }
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

    /// The working animation this session keeps for life: drawn at random the first time the
    /// session is seen, then remembered, so every crab has its own working personality but always
    /// the same one. The draw favours the animations fewest other sessions already took, so a
    /// handful of crabs rarely end up as twins.
    static func workingKey(for id: String) -> String {
        load()
        guard !workingKeys.isEmpty else { return "working" }
        if let picked = workingPicks[id], workingKeys.contains(picked) { return picked }

        var counts: [String: Int] = [:]
        for key in workingPicks.values { counts[key, default: 0] += 1 }
        let fewest = workingKeys.map { counts[$0] ?? 0 }.min() ?? 0
        let candidates = workingKeys.filter { (counts[$0] ?? 0) == fewest }
        let picked = candidates.randomElement() ?? workingKeys[0]

        workingPicks[id] = picked
        UserDefaults.standard.set(workingPicks, forKey: workingPickDefaultsKey)
        if debug { FileHandle.standardError.write(Data("[pets] \(id) -> \(picked)\n".utf8)) }
        return picked
    }

    /// Animation frames for a state key ("working", "moving", …), shared by every crab.
    /// Empty if the state is unknown.
    static func frames(_ state: String) -> [SKTexture] {
        load()
        if let cached = frameCache[state] { return cached }
        guard let sheet = sheets[state], let image = sourceImage(for: sheet) else { return [] }

        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear

        let w = 1.0 / CGFloat(cols), h = 1.0 / CGFloat(rows)
        var out: [SKTexture] = []
        for i in 0..<sheet.frames {
            let col = i % cols, row = i / cols
            // SpriteKit texture rects have their origin at the bottom-left.
            let rect = CGRect(x: CGFloat(col) * w, y: 1 - CGFloat(row + 1) * h, width: w, height: h)
            let t = SKTexture(rect: rect, in: texture)
            t.filteringMode = .linear
            out.append(t)
        }
        frameCache[state] = out
        return out
    }

    private static func sourceImage(for sheet: Sheet) -> CGImage? {
        guard let dir = directory,
              let source = CGImageSourceCreateWithURL(dir.appendingPathComponent(sheet.file) as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    // MARK: - Colour

    /// Per-sprite attribute: this crab's hue rotation in radians, away from the pets' own orange.
    static let hueAttribute = "a_hue"

    /// Rotates every pixel's hue by the sprite's `a_hue`. The texture is premultiplied, so the colour
    /// is un-premultiplied, rotated about the grey axis, and premultiplied again.
    static let hueShader: SKShader = {
        let shader = SKShader(source: """
        void main() {
            vec4 c = texture2D(u_texture, v_tex_coord);
            if (c.a > 0.001 && abs(a_hue) > 0.001) {
                vec3 rgb = c.rgb / c.a;
                vec3 k = vec3(0.57735026919);
                float cs = cos(a_hue);
                float sn = sin(a_hue);
                rgb = rgb * cs + cross(k, rgb) * sn + k * dot(k, rgb) * (1.0 - cs);
                c.rgb = clamp(rgb, 0.0, 1.0) * c.a;
            }
            gl_FragColor = c * v_color_mix.a;
        }
        """)
        shader.attributes = [SKAttribute(name: hueAttribute, type: .float)]
        return shader
    }()

    static func hueValue(degrees: CGFloat) -> SKAttributeValue {
        SKAttributeValue(float: Float((degrees - baseHueDegrees) * .pi / 180))
    }
}
