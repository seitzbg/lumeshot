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
    let onAction: (EditorResult) -> Void
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
        ToolItem(tool: .crop, label: "Crop", symbol: "crop"),
        ToolItem(tool: .text, label: "Text", symbol: "textformat"),
        ToolItem(tool: .highlighter, label: "Highlighter", symbol: "highlighter"),
        ToolItem(tool: .blur, label: "Blur", symbol: "drop"),
        ToolItem(tool: .pixelate, label: "Pixelate", symbol: "squareshape.split.3x3"),
        ToolItem(tool: .step, label: "Step", symbol: "1.circle"),
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

            inspector

            Divider().frame(height: 20)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo || model.editingTextID != nil).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo || model.editingTextID != nil).help("Redo")
            Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                .disabled(model.selectedAnnotation == nil).help("Delete selected")

            Spacer()

            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Copy") { commit(.copy) }
                .help("Copy the annotated image to the clipboard")
            Button("Save") { commit(.save) }
                .help("Save to disk")
                .keyboardShortcut(.defaultAction)
            Button("Upload") { commit(.upload) }
                .help("Save and upload")
        }
        .padding(8)
    }

    /// Flattens the document and reports the chosen action, or fails loud + cancels.
    private func commit(_ action: EditorAction) {
        if let image = model.flatten() {
            onAction(EditorResult(action: action, image: image))
        } else {
            AppLog.log("Editor: flatten failed; discarding capture")
            onCancel()
        }
    }

    /// The tool the inspector should key on: the SELECTED annotation's own kind when
    /// the Select tool is active and something matching an inspector-backed shape is
    /// selected, else the active drawing tool. Otherwise selecting an existing text/
    /// blur/pixelate annotation would show an empty inspector (`.select` → EmptyView),
    /// making it un-editable via the toolbar.
    private var effectiveInspectorTool: EditorTool {
        guard model.activeTool == .select, let selected = model.selectedAnnotation else {
            return model.activeTool
        }
        switch selected.shape {
        case .text: return .text
        case .blur: return .blur
        case .pixelate: return .pixelate
        default: return model.activeTool
        }
    }

    /// Tool-specific creation parameters. Editing a control changes the model's
    /// published default; releasing it (`onEditingChanged == false`) applies the value
    /// to a matching selected shape via `applyInspectorToSelection()`.
    @ViewBuilder private var inspector: some View {
        switch effectiveInspectorTool {
        case .text:
            Stepper("Text \(Int(model.textFontSize))pt",
                    value: $model.textFontSize, in: 8...96, step: 1,
                    onEditingChanged: { editing in if !editing { model.applyInspectorToSelection() } })
                .fixedSize()
                .help("Text size")
        case .blur:
            HStack(spacing: 4) {
                Image(systemName: "drop")
                Slider(value: $model.blurRadius, in: 1...40,
                       onEditingChanged: { editing in if !editing { model.applyInspectorToSelection() } })
                    .frame(width: 90)
            }
            .help("Blur radius")
        case .pixelate:
            HStack(spacing: 4) {
                Image(systemName: "squareshape.split.3x3")
                Slider(value: $model.pixelScale, in: 4...40,
                       onEditingChanged: { editing in if !editing { model.applyInspectorToSelection() } })
                    .frame(width: 90)
            }
            .help("Pixelate scale")
        default:
            EmptyView()
        }
    }
}
