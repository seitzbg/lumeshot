import SwiftUI
import AppKit
import SXAnnotate

private extension Color {
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

private extension RGBAColor {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .red
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                  b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    let onDone: (CGImage) -> Void
    let onCancel: () -> Void

    private struct ToolItem: Identifiable {
        let tool: EditorTool
        let label: String
        let symbol: String
        var id: EditorTool { tool }
    }

    private let tools: [ToolItem] = [
        ToolItem(tool: .select, label: "Select", symbol: "cursorarrow"),
        ToolItem(tool: .rectangle, label: "Rectangle", symbol: "rectangle"),
        ToolItem(tool: .ellipse, label: "Ellipse", symbol: "circle"),
        ToolItem(tool: .line, label: "Line", symbol: "line.diagonal"),
        ToolItem(tool: .arrow, label: "Arrow", symbol: "arrow.up.right"),
        ToolItem(tool: .freehand, label: "Freehand", symbol: "scribble"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            EditorCanvasView(model: model)
                .frame(minWidth: 480, minHeight: 360)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            ForEach(tools) { item in
                Button {
                    model.setTool(item.tool)
                } label: {
                    Image(systemName: item.symbol)
                        .frame(width: 22, height: 22)
                }
                .help(item.label)
                .buttonStyle(.borderless)
                .background(model.activeTool == item.tool
                            ? Color.accentColor.opacity(0.25) : Color.clear)
                .cornerRadius(4)
            }

            Divider().frame(height: 20)

            ColorPicker("", selection: Binding(
                get: { Color(rgba: model.strokeColor) },
                set: { model.strokeColor = RGBAColor(color: $0) }))
                .labelsHidden()
                .help("Stroke color")

            Slider(value: $model.strokeWidth, in: 1...40)
                .frame(width: 90)
                .help("Stroke width")

            Divider().frame(height: 20)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo).help("Redo")
            Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                .disabled(model.selectedAnnotation == nil).help("Delete selected")

            Spacer()

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Done") {
                if let image = model.flatten() { onDone(image) } else { onCancel() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(8)
    }
}
