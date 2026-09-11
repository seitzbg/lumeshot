import Foundation
import Testing
@testable import LumeshotApp

/// The bundle used to declare itself an alternate viewer for MP4 and GIF, but
/// the sole open handler imported every file as a `.sxcu` uploader config —
/// reading the whole file and failing to decode it. Only `.sxcu` is handled;
/// media files are declined so they are neither read wholesale nor mis-parsed.
@MainActor @Suite struct OpenFileRoutingTests {
    @Test func onlySxcuFilesAreHandled() {
        #expect(AppDelegate.handlesOpenedFile("uploader.sxcu"))
        #expect(AppDelegate.handlesOpenedFile("/tmp/UPLOADER.SXCU"))   // case-insensitive
    }

    @Test(arguments: ["recording.mp4", "clip.MP4", "animation.gif", "shot.png", "noextension"])
    func mediaAndOtherFilesAreDeclined(name: String) {
        #expect(!AppDelegate.handlesOpenedFile(name))
    }
}
