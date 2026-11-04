import Foundation

/// The app must make no request to the upstream repository: no update checks,
/// no GitHub API metadata and no avatars.
enum UpstreamDisconnectTests {
    static func run() {
        testSourceRepositoryIsUsersRepo()
        testSourcesMakeNoUpstreamRequests()
    }

    private static func testSourceRepositoryIsUsersRepo() {
        TestSupport.expectEqual(
            UpdateManager.sourceRepositoryURL.absoluteString,
            "https://github.com/kreshiv9/freeflow"
        )
        TestSupport.expectEqual(
            UpdateManager.sourceRepositoryURL.absoluteString,
            "https://github.com/" + UpdateManager.sourceRepositoryName
        )
    }

    /// Static scan of the app sources. make runs the test runner from the
    /// repository root, which is two levels above this file.
    private static func testSourcesMakeNoUpstreamRequests() {
        let repositoryRoot = URL(fileURLWithPath: #filePath).absoluteURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesURL = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sourcesURL, includingPropertiesForKeys: nil) else {
            fatalError("Could not enumerate Sources")
        }

        let bannedNeedles = ["api.github.com", "avatars.githubusercontent.com", "github.com/zachlatta"]
        let updaterNetworkNeedles = ["URLSession", "URLRequest"]
        var scannedCount = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                fatalError("Could not read \(fileURL.lastPathComponent)")
            }
            scannedCount += 1
            let fileName = fileURL.lastPathComponent
            for needle in bannedNeedles {
                TestSupport.expect(!contents.contains(needle), "\(fileName) contains \(needle)")
            }
            if fileName == "UpdateManager.swift" {
                for needle in updaterNetworkNeedles {
                    TestSupport.expect(!contents.contains(needle), "\(fileName) contains \(needle)")
                }
            }
        }
        TestSupport.expect(scannedCount > 50, "Expected more than 50 source files, scanned \(scannedCount)")
    }
}
