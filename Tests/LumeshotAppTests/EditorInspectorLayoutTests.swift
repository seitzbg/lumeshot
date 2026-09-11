import AppKit
import SwiftUI
import Testing
import LumeshotAnnotate
@testable import LumeshotApp

@MainActor @Suite struct EditorInspectorLayoutTests {
    private func base() -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    /// The minimum width the editor needs to lay out with `tool` active, measured
    /// from the real SwiftUI view hosted offscreen — the width below which its
    /// fixed-size controls (the finish buttons) would be compressed or clipped.
    private func fittingWidth(_ tool: EditorTool) -> CGFloat {
        let model = EditorModel(baseImage: base())
        model.setTool(tool)
        let host = NSHostingController(rootView: EditorView(model: model, onAction: { _ in }, onCancel: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        return host.view.fittingSize.width
    }

    /// The top bar's finish buttons are fixed width, so a tool inspector placed
    /// beside them pushed the required width past the window minimum and clipped
    /// Upload. With the inspector moved into the rail, switching to any
    /// inspector-backed tool must not widen the editor beyond the Select case.
    @Test func inspectorToolsDoNotWidenTheEditorBeyondSelect() {
        let selectWidth = fittingWidth(.select)
        for tool in [EditorTool.text, .blur, .pixelate] {
            let w = fittingWidth(tool)
            #expect(w <= selectWidth + 0.5, "\(tool) needs \(w)pt vs Select's \(selectWidth)pt")
        }
    }

    /// And every tool still fits inside the window's content-width minimum, so
    /// nothing in the top bar is clipped at the smallest a capture opens to.
    @Test func everyInspectorToolFitsTheWindowMinimum() {
        for tool in [EditorTool.select, .text, .blur, .pixelate] {
            let w = fittingWidth(tool)
            #expect(w <= 760.5, "\(tool) needs \(w)pt, past the 760pt minimum")
        }
    }
}
