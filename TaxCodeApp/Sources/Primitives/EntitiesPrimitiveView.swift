import SwiftUI

struct EntitiesPrimitiveView: View {
    @Binding var entities: [EntityPrimitive]
    @Binding var selectedID: UUID?
    let onAdd: () -> Void

    private var selectedIndex: Int? {
        guard let selectedID else { return entities.indices.first }
        return entities.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Entities")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)

                Divider()

                List(selection: $selectedID) {
                    ForEach(entities) { entity in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entity.name.isEmpty ? "Untitled" : entity.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text("\(entity.jurisdiction) \(entity.legalForm) • \(entity.classification.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(entity.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                deleteEntity(entity.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)

            if let idx = selectedIndex, entities.indices.contains(idx) {
                Form {
                    Section {
                        TextField("Name", text: $entities[idx].name)
                        TextField("Jurisdiction (e.g. DE, NY, KY, Cayman)", text: $entities[idx].jurisdiction)
                        TextField("Legal Form (e.g. LLC, Corp, LP, S.à r.l.)", text: $entities[idx].legalForm)
                        Picker("Tax Classification", selection: $entities[idx].classification) {
                            ForEach(TaxClassification.allCases) { cls in
                                Text(cls.rawValue).tag(cls)
                            }
                        }
                    }

                    Section("Notes") {
                        TextEditor(text: $entities[idx].notes)
                            .font(.body)
                            .frame(minHeight: 140)
                    }

                    Section {
                        Button("Delete Entity", role: .destructive) {
                            deleteEntity(entities[idx].id)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                VStack {
                    Button("New Entity", action: onAdd)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func deleteEntity(_ id: UUID) {
        entities.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = entities.first?.id
        }
    }
}
