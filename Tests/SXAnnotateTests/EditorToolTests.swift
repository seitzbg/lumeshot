import Testing
@testable import SXAnnotate

@Suite struct EditorToolTests {
    @Test func allCasesIncludeTheSixM3bTools() {
        let all = Set(EditorTool.allCases)
        for tool in [EditorTool.crop, .text, .highlighter, .blur, .pixelate, .step] {
            #expect(all.contains(tool))
        }
    }

    @Test func toolCountIsTwelve() {
        #expect(EditorTool.allCases.count == 12)
    }

    @Test func newToolsHaveStableRawValues() {
        #expect(EditorTool.crop.rawValue == "crop")
        #expect(EditorTool.text.rawValue == "text")
        #expect(EditorTool.highlighter.rawValue == "highlighter")
        #expect(EditorTool.blur.rawValue == "blur")
        #expect(EditorTool.pixelate.rawValue == "pixelate")
        #expect(EditorTool.step.rawValue == "step")
    }
}
