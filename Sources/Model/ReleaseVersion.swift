/// Version strings as release tags and nvm directories spell them.
enum ReleaseVersion {
    /// Numeric component-wise compare so "0.0.10" > "0.0.9". A leading "v" is tolerated: release
    /// tags and nvm directories both carry one.
    ///
    /// Everything from the first non-numeric component on is dropped, so a pre-release compares as
    /// its own base version and never above it. Mapping an unparsable component to 0 instead had
    /// "0.6.0-rc.1" split into 0, 6, "0-rc" -> 0, 1 — one component longer than "0.6.0" and
    /// therefore newer, which is backwards: a release candidate would have been offered as an
    /// update to the release it precedes.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let parts = { (s: String) in
            s.drop(while: { $0 == "v" }).split(separator: ".")
                .prefix(while: { Int($0) != nil }).map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
