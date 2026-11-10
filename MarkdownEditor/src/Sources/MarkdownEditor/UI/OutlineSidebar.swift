import SwiftUI

/// Headings of the document, indented by level; click to jump. The section
/// containing the caret is highlighted.
struct OutlineSidebar: View {
    let session: DocumentSession

    /// Created lazily in `.task`: SwiftUI may build (and discard) this view
    /// struct many times, and each model registers notification observers.
    @State private var model: OutlineModel?

    var body: some View {
        Group {
            if let model, !model.headings.isEmpty {
                list(model)
            } else {
                ContentUnavailableView {
                    Label("No Headings", systemImage: "list.bullet.indent")
                } description: {
                    Text("Lines starting with # appear here.")
                }
            }
        }
        .task {
            if model == nil { model = OutlineModel(editor: session.editor) }
        }
    }

    private func list(_ model: OutlineModel) -> some View {
        let minimumLevel = model.minimumLevel
        return ScrollViewReader { proxy in
            List(model.headings) { heading in
                let isCurrent = heading.id == model.currentIndex
                Button {
                    go(to: heading)
                } label: {
                    Text(heading.title.isEmpty ? "Untitled" : heading.title)
                        .font(heading.level == minimumLevel ? .body.weight(.semibold) : .body)
                        .foregroundStyle(heading.title.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, CGFloat(heading.level - minimumLevel) * 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(heading.title)
                .listRowBackground(
                    isCurrent
                        ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 8)
                        : nil
                )
                .id(heading.id)
            }
            .listStyle(.sidebar)
            .onChange(of: model.currentIndex) {
                guard let index = model.currentIndex else { return }
                withAnimation { proxy.scrollTo(index) }
            }
        }
    }

    private func go(to heading: OutlineHeading) {
        // The editor is not visible in Preview Only.
        if session.viewMode == .preview { session.viewMode = .split }
        session.editor.goToLine(heading.line)
    }
}
