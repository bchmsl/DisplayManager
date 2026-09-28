import Foundation

/// Converts between `ScreenSetting` and one displayplacer screen spec
/// (`id:<ids> res:3008x1692 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0`).
///
/// Every emitted token passes a strict character whitelist. Specs are passed to `Process` as separate
/// arguments (never through a shell), and the whitelist also keeps the copyable raw command safe when
/// the data came from an imported file.
public enum ScreenSpecCodec {
    private static let tokenCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:()_,.+-")
    private static let idCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    private static let keyCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_")

    private static let knownKeys: Set<String> = ["id", "res", "hz", "color_depth", "enabled", "scaling", "origin", "degree"]

    // MARK: Encoding

    public static func encode(_ setting: ScreenSetting) throws -> String {
        try tokens(for: setting).joined(separator: " ")
    }

    public static func tokens(for setting: ScreenSetting) throws -> [String] {
        guard !setting.displayIDs.isEmpty else { throw DisplayManagerError.invalidScreenSpec("missing id") }
        for id in setting.displayIDs { try validateID(id) }
        var tokens = ["id:" + setting.displayIDs.joined(separator: "+")]
        guard setting.enabled else {
            tokens.append("enabled:false")
            return tokens
        }
        if let resolution = setting.resolution { tokens.append("res:\(resolution.width)x\(resolution.height)") }
        if let hz = setting.refreshRate { tokens.append("hz:\(hz)") }
        if let depth = setting.colorDepth { tokens.append("color_depth:\(depth)") }
        tokens.append("enabled:true")
        if let scaling = setting.scaling { tokens.append("scaling:\(scaling ? "on" : "off")") }
        if let origin = setting.origin { tokens.append("origin:(\(origin.x),\(origin.y))") }
        if let rotation = setting.rotation { tokens.append("degree:\(rotation)") }
        for key in setting.extraArguments.keys.sorted() {
            guard !knownKeys.contains(key), let value = setting.extraArguments[key] else { continue }
            tokens.append("\(key):\(value)")
        }
        for token in tokens { try validateToken(token) }
        return tokens
    }

    // MARK: Decoding

    public static func decode(_ spec: String) throws -> ScreenSetting {
        let tokens = spec.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { throw DisplayManagerError.invalidScreenSpec(spec) }

        var ids: [String]?
        var enabled = true
        var setting = ScreenSetting(displayIDs: [])
        for token in tokens {
            try validateToken(token)
            guard let colon = token.firstIndex(of: ":") else { throw DisplayManagerError.invalidScreenSpec(token) }
            let key = String(token[..<colon])
            let value = String(token[token.index(after: colon)...])
            guard !key.isEmpty, !value.isEmpty else { throw DisplayManagerError.invalidScreenSpec(token) }
            switch key {
            case "id":
                let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
                for part in parts { try validateID(part) }
                ids = parts
            case "res":
                guard let size = parseSize(value) else { throw DisplayManagerError.invalidScreenSpec(token) }
                setting.resolution = size
            case "hz":
                guard let hz = Int(value) else { throw DisplayManagerError.invalidScreenSpec(token) }
                setting.refreshRate = hz
            case "color_depth":
                guard let depth = Int(value) else { throw DisplayManagerError.invalidScreenSpec(token) }
                setting.colorDepth = depth
            case "enabled":
                guard let flag = parseBool(value, trueWord: "true", falseWord: "false") else {
                    throw DisplayManagerError.invalidScreenSpec(token)
                }
                enabled = flag
            case "scaling":
                guard let flag = parseBool(value, trueWord: "on", falseWord: "off") else {
                    throw DisplayManagerError.invalidScreenSpec(token)
                }
                setting.scaling = flag
            case "origin":
                guard let point = parsePoint(value) else { throw DisplayManagerError.invalidScreenSpec(token) }
                setting.origin = point
            case "degree":
                guard let degree = Int(value) else { throw DisplayManagerError.invalidScreenSpec(token) }
                setting.rotation = degree
            default:
                guard key.unicodeScalars.allSatisfy(keyCharacters.contains) else {
                    throw DisplayManagerError.invalidScreenSpec(token)
                }
                setting.extraArguments[key] = value
            }
        }
        guard let ids, !ids.isEmpty else { throw DisplayManagerError.invalidScreenSpec(spec) }
        setting.displayIDs = ids
        setting.enabled = enabled
        return setting
    }

    // MARK: Validation

    public static func validateToken(_ token: String) throws {
        guard !token.isEmpty, token.unicodeScalars.allSatisfy(tokenCharacters.contains) else {
            throw DisplayManagerError.unsafeToken(token)
        }
    }

    public static func validateID(_ id: String) throws {
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(idCharacters.contains) else {
            throw DisplayManagerError.unsafeToken(id)
        }
    }

    /// Validates an unknown `key:value` pair from an imported file.
    public static func validateExtraArgument(key: String, value: String) throws {
        guard !key.isEmpty, key.unicodeScalars.allSatisfy(keyCharacters.contains), !knownKeys.contains(key) else {
            throw DisplayManagerError.unsafeToken(key)
        }
        try validateToken("\(key):\(value)")
    }

    // MARK: Value parsing (shared with the list parser)

    static func parseSize(_ value: String) -> DisplaySize? {
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return DisplaySize(width: width, height: height)
    }

    static func parsePoint(_ value: String) -> DisplayPoint? {
        guard value.hasPrefix("("), value.hasSuffix(")") else { return nil }
        let inner = value.dropFirst().dropLast()
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return DisplayPoint(x: x, y: y)
    }

    static func parseBool(_ value: String, trueWord: String, falseWord: String) -> Bool? {
        switch value.lowercased() {
        case trueWord: true
        case falseWord: false
        default: nil
        }
    }
}
