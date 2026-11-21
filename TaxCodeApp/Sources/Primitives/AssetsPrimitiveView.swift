import SwiftUI

struct AssetsPrimitiveView: View {
    @Binding var assets: [AssetPrimitive]
    let entities: [EntityPrimitive]
    @Binding var selectedID: UUID?
    let onAdd: () -> Void

    private var selectedIndex: Int? {
        guard let selectedID else { return assets.indices.first }
        return assets.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Assets")
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
                    ForEach(assets) { asset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.name.isEmpty ? "Untitled" : asset.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(asset.character.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(asset.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                deleteAsset(asset.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)

            if let idx = selectedIndex, assets.indices.contains(idx) {
                Form {
                    Section {
                        TextField("Asset", text: $assets[idx].name)
                        Picker("Character", selection: $assets[idx].character) {
                            ForEach(AssetCharacter.allCases) { ch in
                                Text(ch.rawValue).tag(ch)
                            }
                        }
                        Picker("Owner", selection: $assets[idx].ownerEntityID) {
                            Text("Unassigned").tag(UUID?.none)
                            ForEach(entities) { entity in
                                Text(entity.name).tag(Optional(entity.id))
                            }
                        }
                    }

                    Section("Basis & Value") {
                        TextField("Adjusted Basis", text: $assets[idx].adjustedBasis)
                            .font(.body.monospacedDigit())
                        TextField("Fair Market Value", text: $assets[idx].fairMarketValue)
                            .font(.body.monospacedDigit())

                        if let gain = builtInGain(basis: assets[idx].adjustedBasis, fmv: assets[idx].fairMarketValue) {
                            LabeledContent(gain >= 0 ? "Built-In Gain" : "Built-In Loss") {
                                Text(gain, format: .currency(code: "USD"))
                                    .font(.headline.monospacedDigit())
                                    .foregroundStyle(gain >= 0 ? Color.primary : Color.orange)
                            }
                        }

                        Toggle(
                            "Track Acquisition Date",
                            isOn: Binding(
                                get: { assets[idx].acquisitionDate != nil },
                                set: { enabled in
                                    assets[idx].acquisitionDate = enabled ? Date() : nil
                                }
                            )
                        )
                        if let acq = assets[idx].acquisitionDate {
                            DatePicker(
                                "Acquired",
                                selection: Binding(
                                    get: { acq },
                                    set: { assets[idx].acquisitionDate = $0 }
                                ),
                                displayedComponents: .date
                            )
                        }
                    }

                    Section("Notes") {
                        TextEditor(text: $assets[idx].notes)
                            .font(.body)
                            .frame(minHeight: 120)
                    }

                    Section {
                        Button("Delete Asset", role: .destructive) {
                            deleteAsset(assets[idx].id)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                VStack {
                    Button("New Asset", action: onAdd)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func builtInGain(basis: String, fmv: String) -> Double? {
        let cleanB = basis.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let cleanF = fmv.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let b = Double(cleanB), let f = Double(cleanF) else { return nil }
        return f - b
    }

    private func deleteAsset(_ id: UUID) {
        assets.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = assets.first?.id
        }
    }
}
