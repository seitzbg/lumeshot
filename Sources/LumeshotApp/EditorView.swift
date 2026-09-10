import SwiftUI
import AppKit
import LumeshotAnnotate

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

    @State private var exportError: String?

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
            topBar
            Divider()
            HStack(spacing: 0) {
                toolRail
                Divider()
                EditorCanvasView(model: model)
                    .frame(minWidth: 480, minHeight: 360)
            }
        }
        // The top bar (colour, width, undo/redo/delete, finish buttons) sets the floor;
        // the tools now live in the left rail, so the window no longer has to be wide
        // enough to lay all of them out in one row.
        .frame(minWidth: 760, minHeight: 480)
        .alert("Couldn’t produce the image",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Vertical tool rail: each drawing tool as an icon + word, so its function is
    /// obvious without hovering for a tooltip. The active tool is boxed and tinted.
    private var toolRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(tools) { item in
                    let isActive = model.activeTool == item.tool
                    Button {
                        model.setTool(item.tool)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol)
                                .frame(width: 18)
                            Text(item.label)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
                    .cornerRadius(6)
                    .help(item.label)
                }
            }
            .padding(6)
        }
        .frame(width: 148)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            // ColorPicker has no onEditingChanged, so every wheel movement lands here.
            // applyStrokeColorToSelection coalesces a run of them into one undo entry.
            ColorPicker("", selection: Binding(
                get: { Color(rgba: model.strokeColor) },
                set: {
                    model.strokeColor = RGBAColor(color: $0)
                    model.applyStrokeColorToSelection()
                }))
                .labelsHidden()
                .help("Stroke color")

            // The grab ends any open colour run, so this edit cannot merge backwards
            // into it; the release applies the width as its own undo entry.
            Slider(value: $model.strokeWidth, in: 1...40,
                   onEditingChanged: { editing in
                       if editing { model.endStrokeStyleRun() }
                       else { model.applyStrokeWidthToSelection() }
                   })
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

            // Icon+label buttons with .fixedSize() so the labels always render in
            // full: crammed into this one toolbar, plain text buttons were being
            // truncated to a single glyph ("C… C… … U…"), hiding the only way to
            // finish. Save/Upload are emphasized as the primary finish actions.
            Button(role: .cancel) { onCancel() } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .keyboardShortcut(.cancelAction)
            .fixedSize()
            .help("Discard this capture")
            Button { commit(.copy) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .fixedSize()
            .help("Copy the annotated image to the clipboard")
            Button { commit(.save) } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .fixedSize()
            .help("Save to disk")
            Button { commit(.upload) } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("Save and upload")
        }
        .padding(8)
    }

    /// Flattens the document and reports the chosen action.
    ///
    /// A failure keeps the editor open. Flattening fails when a redaction could
    /// not be rendered or a crop could not be applied, and in both cases the
    /// image that would have been delivered shows content the user meant to
    /// remove — so the one thing this must not do is hand it onward. Cancelling
    /// instead, as it used to, threw the capture away on a transient error.
    private func commit(_ action: EditorAction) {
        guard let image = model.flatten() else {
            AppLog.log("Editor: flatten failed; keeping the editor open")
            exportError = "The blur, pixelate or crop regions couldn’t be applied, so "
                + "nothing was copied, saved or uploaded. Adjust them and try again."
            return
        }
        onAction(EditorResult(action: action, image: image))
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
