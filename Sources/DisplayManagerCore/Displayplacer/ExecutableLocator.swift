import Foundation

/// A displayplacer version such as 1.4.0.
public struct DisplayplacerVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The list output format this app parses was introduced in 1.4.0.
    public static let minimumSupported = DisplayplacerVersion(major: 1, minor: 4, patch: 0)

    /// Parses `displayplacer --version` output, for example "displayplacer v1.4.0".
    public static func parse(_ output: String) -> DisplayplacerVersion? {
        for word in output.split(whereSeparator: { $0.isWhitespace }) {
            var text = Substring(word)
            if text.first == "v" || text.first == "V" { text = text.dropFirst() }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard (2...3).contains(parts.count),
                  let major = Int(parts[0]),
                  let minor = Int(parts[1])
            else { continue }
            let patch = parts.count == 3 ? Int(parts[2]) : 0
            guard let patch else { continue }
            return DisplayplacerVersion(major: major, minor: minor, patch: patch)
        }
        return nil
    }

    public var isSupported: Bool { self >= Self.minimumSupported }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// Finds the displayplacer executable without running a login shell.
public enum ExecutableLocator {
    public enum Source: String, Hashable, Sendable {
        case userOverride
        case standardLocation
        case searchPath
    }

    public struct Result: Hashable, Sendable {
        /// The executable to run, or nil when none was found.
        public var path: String?
        public var source: Source?
        /// True when a custom path is set but is not an executable file.
        public var overrideIsInvalid: Bool

        public init(path: String?, source: Source?, overrideIsInvalid: Bool) {
            self.path = path
            self.source = source
            self.overrideIsInvalid = overrideIsInvalid
        }
    }

    public static let standardLocations = ["/opt/homebrew/bin/displayplacer", "/usr/local/bin/displayplacer"]

    /// Candidate paths in search order, without duplicates.
    public static func candidates(override: String?, pathEnvironment: String?, homeDirectory: String) -> [(String, Source)] {
        var result: [(String, Source)] = []
        var seen = Set<String>()
        func add(_ path: String, _ source: Source) {
            let normalized = (path as NSString).standardizingPath
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return }
            result.append((normalized, source))
        }
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            add((override as NSString).expandingTildeInPath, .userOverride)
        }
        for location in standardLocations { add(location, .standardLocation) }
        let pathDirectories = (pathEnvironment ?? "").split(separator: ":").map(String.init)
        let extraDirectories = [homeDirectory + "/.local/bin", homeDirectory + "/bin", "/opt/local/bin"]
        for directory in pathDirectories + extraDirectories where directory.hasPrefix("/") {
            add(directory + "/displayplacer", .searchPath)
        }
        return result
    }

    public static func locate(
        override: String?,
        pathEnvironment: String?,
        homeDirectory: String,
        isExecutable: (String) -> Bool
    ) -> Result {
        var overrideIsInvalid = false
        for (path, source) in candidates(override: override, pathEnvironment: pathEnvironment, homeDirectory: homeDirectory) {
            if isExecutable(path) {
                return Result(path: path, source: source, overrideIsInvalid: overrideIsInvalid)
            }
            if source == .userOverride { overrideIsInvalid = true }
        }
        return Result(path: nil, source: nil, overrideIsInvalid: overrideIsInvalid)
    }
}
