import Foundation
import Testing
@testable import LumeshotCore

@Suite struct WebLinkTests {
    @Test(arguments: [
        "https://i.example.net/a.png",
        "http://host/path?q=1",
        "  https://host/x\n",          // surrounding whitespace tolerated
    ])
    func absoluteHTTPURLsAreOpenable(link: String) {
        #expect(WebLink.isOpenable(link))
    }

    @Test(arguments: [
        "file:///Applications/Calculator.app",   // local file
        "myapp://open",                            // another app's handler
        "javascript:alert(1)",
        "ftp://h/a.png",
        "/relative/path",
        "not a url",
        "",
        "   ",
    ])
    func nonWebValuesAreNotOpenable(candidate: String) {
        #expect(!WebLink.isOpenable(candidate))
        #expect(WebLink.openable(candidate) == nil)
    }
}
