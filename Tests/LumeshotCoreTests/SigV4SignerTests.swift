import Foundation
import Testing
@testable import LumeshotCore

@Suite struct SigV4SignerTests {
    /// 2015-08-30T12:36:00Z as a Date.
    private var vectorDate: Date {
        var c = DateComponents()
        c.year = 2015; c.month = 8; c.day = 30
        c.hour = 12; c.minute = 36; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private let emptyPayloadHash =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    @Test func amzDateAndStampAreUTCFormatted() {
        #expect(SigV4Signer.amzDate(vectorDate) == "20150830T123600Z")
        #expect(SigV4Signer.dateStamp(vectorDate) == "20150830")
    }

    @Test func canonicalRequestMatchesGetVanillaVector() {
        let cr = SigV4Signer.canonicalRequest(
            method: "GET", canonicalURI: "/", canonicalQuery: "",
            signedHeaders: ["host": "example.amazonaws.com",
                            "x-amz-date": "20150830T123600Z"],
            payloadHash: emptyPayloadHash)
        let expected = """
        GET
        /

        host:example.amazonaws.com
        x-amz-date:20150830T123600Z

        host;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """
        #expect(cr == expected)
    }

    @Test func authorizationHeaderMatchesGetVanillaVector() {
        let auth = SigV4Signer.authorizationHeader(
            method: "GET", canonicalURI: "/", canonicalQuery: "",
            signedHeaders: ["host": "example.amazonaws.com"],
            payloadHash: emptyPayloadHash,
            region: "us-east-1", service: "service",
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            timestamp: vectorDate)
        #expect(auth == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }
}
