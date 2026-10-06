/// capybar's version, declared here and nowhere else, and the comparisons the updater makes
/// with it. `capybar --version` prints it; `install.sh` and CI compare release tags with it.

let CAPYBAR_VERSION = "0.2.0"

/// Whether text is a release version as capybar tags them: dotted decimal numbers, no "v".
/// @param text A release tag from GitHub. @returns True for "0.2.0" or "1.10", false for "v1.0", "1.0-beta", "".
func isReleaseVersion(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
}

/// Compares two release versions numerically, part by part ("0.10.0" is newer than "0.9.1"; a
/// missing part counts as 0).
/// @param candidate A release version (see `isReleaseVersion`). @param current The version in use.
/// @returns True when `candidate` is newer than `current`.
func isNewer(_ candidate: String, than current: String) -> Bool {
    let left = candidate.split(separator: ".").map { Int($0) ?? 0 }, right = current.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(left.count, right.count) {
        let leftPart = index < left.count ? left[index] : 0, rightPart = index < right.count ? right[index] : 0
        if leftPart != rightPart { return leftPart > rightPart }
    }
    return false
}
