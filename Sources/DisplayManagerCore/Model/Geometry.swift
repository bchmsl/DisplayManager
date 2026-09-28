import Foundation

/// A size in display points, as displayplacer reports it (`res:3008x1692`).
public struct DisplaySize: Codable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The same size with width and height swapped (used for 90° and 270° rotation).
    public var transposed: DisplaySize { DisplaySize(width: height, height: width) }

    public var description: String { "\(width)x\(height)" }
}

/// A point in global display coordinates: main display at (0,0), y grows downward.
public struct DisplayPoint: Codable, Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public static let zero = DisplayPoint(x: 0, y: 0)

    public var description: String { "(\(x),\(y))" }
}

/// A rectangle in global display coordinates (points).
public struct DisplayRect: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(origin: DisplayPoint, size: DisplaySize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    public var origin: DisplayPoint { DisplayPoint(x: x, y: y) }
    public var size: DisplaySize { DisplaySize(width: width, height: height) }
}
