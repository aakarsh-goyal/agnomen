import Foundation

/// The Finder "Comments" field (Get Info) is the `kMDItemFinderComment` extended attribute, which Spotlight
/// indexes. Writing the model's one-line description there makes renamed files searchable by what they
/// are about. Existing comments are never overwritten.
enum FinderComment {
    static let attr = "com.apple.metadata:kMDItemFinderComment"

    static func read(_ path: String) -> String? {
        let n = getxattr(path, attr, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        guard getxattr(path, attr, &buf, n, 0, 0) == n else { return nil }
        return (try? PropertyListSerialization.propertyList(from: Data(buf), options: [], format: nil)) as? String
    }

    @discardableResult
    static func write(_ text: String, to path: String) -> Bool {
        guard let d = try? PropertyListSerialization.data(fromPropertyList: text, format: .binary, options: 0) else { return false }
        return d.withUnsafeBytes { setxattr(path, attr, $0.baseAddress, d.count, 0, 0) } == 0
    }

    static func remove(_ path: String) { removexattr(path, attr, 0) }
}
