import Foundation

/// Parses `displayplacer list` output (format of displayplacer 1.4.0).
///
/// The final `displayplacer "…" "…"` line is the authoritative configuration. The per-screen blocks add
/// metadata (ids, type, main flag, enabled state, supported modes). Unknown labels are kept.
public enum ListOutputParser {
    private static let footerPrefix = "Execute the command below"

    public static func parse(_ output: String) throws -> ParsedList {
        let lines = output.components(separatedBy: .newlines)
        guard let commandLine = lines.last(where: { isCommandLine($0) })?.trimmingCharacters(in: .whitespaces) else {
            throw DisplayManagerError.malformedListOutput(detail: "No displayplacer command line found.\n" + snippet(output))
        }
        let configuration = try parseCommandLine(commandLine)
        let screens = parseScreens(lines)
        return ParsedList(screens: screens, configuration: configuration, commandLine: commandLine)
    }

    // MARK: Command line

    static func isCommandLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("displayplacer \"") || trimmed.hasPrefix("displayplacer '")
    }

    /// Splits `displayplacer "spec" "spec"` into screen settings.
    public static func parseCommandLine(_ line: String) throws -> [ScreenSetting] {
        let words = try tokenize(line)
        guard words.first == "displayplacer", words.count > 1 else {
            throw DisplayManagerError.malformedListOutput(detail: "Unexpected command line: \(line)")
        }
        do {
            return try words.dropFirst().map(ScreenSpecCodec.decode)
        } catch {
            throw DisplayManagerError.malformedListOutput(detail: "Could not parse command line: \(line)\n\(error)")
        }
    }

    /// Quote-aware split: whitespace separates words; single or double quotes group them.
    static func tokenize(_ line: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        for character in line {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            } else {
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil else {
            throw DisplayManagerError.malformedListOutput(detail: "Unbalanced quotes in: \(line)")
        }
        if inWord { words.append(current) }
        return words
    }

    // MARK: Screen blocks

    static func parseScreens(_ lines: [String]) -> [ParsedScreen] {
        var screens: [ParsedScreen] = []
        var current: ParsedScreen?
        var inModes = false

        func finish() {
            if let screen = current { screens.append(screen) }
            current = nil
            inModes = false
        }

        for rawLine in lines {
            if rawLine.hasPrefix(footerPrefix) || isCommandLine(rawLine) {
                finish()
                break
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                inModes = false
                continue
            }
            if inModes, line.hasPrefix("mode "), current != nil {
                if let mode = parseMode(line) { current?.modes.append(mode) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            if label == "Persistent screen id" {
                finish()
                current = ParsedScreen(persistentID: value)
                continue
            }
            if current == nil {
                // Older formats may start a block with another label.
                guard label == "Contextual screen id" || label == "Serial screen id" else { continue }
                current = ParsedScreen()
            }
            inModes = false
            apply(label: label, value: value, to: &current)
            if label.hasPrefix("Resolutions for rotation") {
                inModes = true
                current?.modesRotation = leadingInt(String(label.dropFirst("Resolutions for rotation".count)))
            }
        }
        finish()
        return screens
    }

    private static func apply(label: String, value: String, to screen: inout ParsedScreen?) {
        switch label {
        case "Contextual screen id":
            screen?.contextualID = Int(value)
        case "Serial screen id":
            screen?.serialID = value
        case "Type":
            screen?.typeDescription = value
        case "Resolution":
            screen?.resolution = ScreenSpecCodec.parseSize(value)
        case "Hertz":
            screen?.refreshRate = Int(value)
        case "Color Depth":
            screen?.colorDepth = Int(value)
        case "Scaling":
            screen?.scaling = ScreenSpecCodec.parseBool(value, trueWord: "on", falseWord: "off")
        case "Origin":
            let pointText = value.split(separator: " ").first.map(String.init) ?? value
            screen?.origin = ScreenSpecCodec.parsePoint(pointText)
            screen?.isMain = value.contains("main display")
        case "Rotation":
            screen?.rotation = leadingInt(value)
        case "Enabled":
            screen?.enabled = ScreenSpecCodec.parseBool(value, trueWord: "true", falseWord: "false")
        default:
            if label.hasPrefix("Resolutions for rotation") { return }
            screen?.extraFields[label] = value
        }
    }

    /// Parses `mode 66: res:1800x1169 hz:120 color_depth:8 scaling:on <-- current mode`.
    static func parseMode(_ line: String) -> DisplayMode? {
        guard let colon = line.firstIndex(of: ":"),
              let number = Int(line[line.index(line.startIndex, offsetBy: 5)..<colon].trimmingCharacters(in: .whitespaces))
        else { return nil }
        let rest = line[line.index(after: colon)...]
        var resolution: DisplaySize?
        var hz: Int?
        var depth: Int?
        var scaling = false
        for token in rest.split(separator: " ") {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "res": resolution = ScreenSpecCodec.parseSize(parts[1])
            case "hz": hz = Int(parts[1])
            case "color_depth": depth = Int(parts[1])
            case "scaling": scaling = parts[1] == "on"
            default: break
            }
        }
        guard let resolution else { return nil }
        return DisplayMode(
            number: number,
            resolution: resolution,
            refreshRate: hz,
            colorDepth: depth,
            scaling: scaling,
            isCurrent: line.contains("<-- current mode")
        )
    }

    private static func leadingInt(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = ""
        for character in trimmed {
            if character.isNumber || (digits.isEmpty && character == "-") {
                digits.append(character)
            } else {
                break
            }
        }
        return Int(digits)
    }

    private static func snippet(_ output: String) -> String {
        let limit = 2000
        return output.count > limit ? String(output.prefix(limit)) + "…" : output
    }
}
