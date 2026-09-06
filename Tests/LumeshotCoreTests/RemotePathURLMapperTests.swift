import Foundation
import Testing
@testable import LumeshotCore

@Suite struct RemotePathURLMapperTests {
    @Test func remotePathJoinsDirectoryWithoutTrailingSlash() {
        #expect(RemotePathURLMapper.remotePath(directory: "/home/bob/uploads", filename: "shot.png")
                == "/home/bob/uploads/shot.png")
    }

    @Test func remotePathTrimsDirectoryTrailingSlash() {
        #expect(RemotePathURLMapper.remotePath(directory: "/home/bob/uploads/", filename: "shot.png")
                == "/home/bob/uploads/shot.png")
    }

    @Test func remotePathWithEmptyDirectoryYieldsRootedFilename() {
        #expect(RemotePathURLMapper.remotePath(directory: "", filename: "shot.png") == "/shot.png")
    }

    @Test func remotePathPreservesFilenameSubpath() {
        #expect(RemotePathURLMapper.remotePath(directory: "/uploads", filename: "2026/shot.png")
                == "/uploads/2026/shot.png")
    }

    @Test func resultURLJoinsBaseWithoutTrailingSlash() {
        #expect(RemotePathURLMapper.resultURL(publicURLBase: "https://cdn.example.com/uploads",
                                              filename: "shot.png")
                == "https://cdn.example.com/uploads/shot.png")
    }

    @Test func resultURLTrimsBaseTrailingSlash() {
        #expect(RemotePathURLMapper.resultURL(publicURLBase: "https://cdn.example.com/uploads/",
                                              filename: "shot.png")
                == "https://cdn.example.com/uploads/shot.png")
    }

    @Test func resultURLPreservesFilenameSubpath() {
        #expect(RemotePathURLMapper.resultURL(publicURLBase: "https://cdn.example.com/up",
                                              filename: "2026/shot.png")
                == "https://cdn.example.com/up/2026/shot.png")
    }
}

@Suite struct RemotePathEncodingTests {
    /// The filesystem/SFTP path is handed to a file API, not a URL parser, so
    /// it must stay literal — only URL construction encodes.
    @Test func remotePathIsNotEncoded() {
        #expect(RemotePathURLMapper.remotePath(directory: "/up", filename: "my shot #2.png")
                == "/up/my shot #2.png")
    }

    @Test(arguments: [
        ("my shot.png", "my%20shot.png"),
        ("a#b.png", "a%23b.png"),
        ("a?b.png", "a%3Fb.png"),
        ("100%.png", "100%25.png"),
        ("café.png", "caf%C3%A9.png"),
        ("a+b.png", "a%2Bb.png"),
        ("plain-file_1.~png", "plain-file_1.~png"),   // unreserved survive verbatim
    ])
    func resultURLEncodesTheFilename(filename: String, encoded: String) {
        #expect(RemotePathURLMapper.resultURL(publicURLBase: "https://cdn.example.com/u",
                                              filename: filename)
                == "https://cdn.example.com/u/\(encoded)")
    }

    @Test func encodePathPreservesSeparators() {
        #expect(RemotePathURLMapper.encodePath("/up/my dir/a b.png") == "/up/my%20dir/a%20b.png")
    }

    @Test func anEncodedResultURLStillParses() throws {
        let url = RemotePathURLMapper.resultURL(publicURLBase: "https://cdn.example.com/u",
                                                filename: "my shot #2.png")
        let parsed = try #require(URL(string: url))
        #expect(parsed.fragment == nil)     // "#2.png" must not become a fragment
        #expect(parsed.lastPathComponent == "my shot #2.png")
    }
}
