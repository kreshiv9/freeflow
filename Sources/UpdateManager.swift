import Foundation

// MARK: - Versions

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("v") || normalized.hasPrefix("V") {
            normalized.removeFirst()
        }

        let withoutBuildMetadata = normalized.split(separator: "+", maxSplits: 1).first.map(String.init) ?? normalized
        let versionAndPrerelease = withoutBuildMetadata
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        let coreComponents = versionAndPrerelease[0].split(separator: ".").map(String.init)

        guard coreComponents.count == 3,
              let major = Int(coreComponents[0]),
              let minor = Int(coreComponents[1]),
              let patch = Int(coreComponents[2]) else {
            return nil
        }

        let parsedPrerelease: [String]
        if versionAndPrerelease.count > 1 {
            let prereleaseRaw = versionAndPrerelease[1]
            guard !prereleaseRaw.isEmpty else { return nil }
            parsedPrerelease = prereleaseRaw
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard parsedPrerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        } else {
            parsedPrerelease = []
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = parsedPrerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }

            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left < right
            }
        }

        return lhs.prerelease.count < rhs.prerelease.count
    }
}

// MARK: - Updates

/// FreeFlow never checks for, downloads or installs updates, so it makes no
/// update request. New versions come from pulling and rebuilding this repository.
enum UpdateManager {
    static let sourceRepositoryName = "kreshiv9/freeflow"
    static let sourceRepositoryURL = URL(string: "https://github.com/kreshiv9/freeflow")!
}
