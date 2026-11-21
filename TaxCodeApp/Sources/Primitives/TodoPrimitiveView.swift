import SwiftUI

struct TodoPrimitiveView: View {
    @Binding var todos: [TodoItem]
    @State private var draftText = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .foregroundStyle(.secondary)
                TextField("New item", text: $draftText)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onSubmit(addItem)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .padding(16)

            if !todos.isEmpty {
                Divider()
                List {
                    ForEach($todos) { $item in
                        HStack(spacing: 10) {
                            Button {
                                item.isCompleted.toggle()
                            } label: {
                                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            TextField("", text: $item.text)
                                .textFieldStyle(.plain)
                                .strikethrough(item.isCompleted)
                                .foregroundStyle(item.isCompleted ? .secondary : .primary)

                            Spacer()

                            Button {
                                todos.removeAll { $0.id == item.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        todos.move(fromOffsets: from, toOffset: to)
                    }
                }
                .listStyle(.plain)
            } else {
                Spacer()
            }
        }
        .onAppear {
            inputFocused = true
        }
    }

    private func addItem() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.insert(TodoItem(text: trimmed), at: 0)
        draftText = ""
    }
}
