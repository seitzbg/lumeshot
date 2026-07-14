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
