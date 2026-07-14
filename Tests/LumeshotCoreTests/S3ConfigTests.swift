import Foundation
import Testing
@testable import LumeshotCore

@Suite struct S3ConfigTests {
    @Test func s3DestinationRoundTripsThroughUploadSettings() throws {
        let config = S3Config(region: "us-east-1", endpoint: "s3.us-east-1.amazonaws.com",
                              bucket: "shots", objectPrefix: "screens/",
                              addressingStyle: .path, acl: "public-read",
                              customDomain: "cdn.example.com")
        let dest = UploadDestination(id: "d1", name: "My S3", kind: .s3, s3Config: config)
        let settings = UploadSettings(uploadAfterCapture: true, activeDestinationID: "d1",
                                      destinations: [dest])

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(UploadSettings.self, from: data)

        #expect(decoded == settings)
        #expect(decoded.destinations.first?.kind == .s3)
        #expect(decoded.destinations.first?.s3Config?.bucket == "shots")
        #expect(decoded.destinations.first?.s3Config?.addressingStyle == .path)
    }

    @Test func s3ConfigDefaultsAreVirtualHostNoAcl() {
        let config = S3Config(region: "auto", endpoint: "acct.r2.cloudflarestorage.com",
                              bucket: "b")
        #expect(config.addressingStyle == .virtualHost)
        #expect(config.acl == nil)
        #expect(config.objectPrefix == "")
    }
}
