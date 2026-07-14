import CoreGraphics
import Foundation
import Testing
@testable import LumeshotCapture

func makeTestImage(width: Int = 4, height: Int = 4) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

@Suite struct ImageEncoderTests {
    @Test func encodesPNGWithMagicBytes() {
        let data = ImageEncoder.png(from: makeTestImage())
        #expect(data != nil)
        #expect(Array(data!.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }
}
