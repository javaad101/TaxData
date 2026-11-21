import SwiftUI
import TaxData

/// Renders USLM XHTML `<table>`, eCFR `<TABLE>`, and GPO `<GPOTABLE>` elements.
struct StatutoryTableView: View {
    let tableNode: DocumentNode

    var body: some View {
        let rows = extractRows()
        if !rows.isEmpty {
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                        GridRow {
                            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(row.isHeader ? .caption.weight(.bold) : .caption)
                                    .textSelection(.enabled)
                                    .frame(minWidth: 90, maxWidth: 280, alignment: .leading)
                                    .padding(.vertical, 3)
                            }
                        }
                        if row.isHeader || rIdx < rows.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(10)
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private struct TableRowData {
        var isHeader: Bool
        var cells: [String]
    }

    private func extractRows() -> [TableRowData] {
        var out: [TableRowData] = []
        if tableNode.key == "GPOTABLE" {
            if let boxhd = tableNode.firstElement(forKey: "BOXHD") {
                let headers = boxhd["CHED"].map(\.normalizedText).filter { !$0.isEmpty }
                if !headers.isEmpty {
                    out.append(TableRowData(isHeader: true, cells: headers))
                }
            }
            for row in tableNode["ROW"] {
                let cells = row["ENT"].map(\.normalizedText)
                if !cells.isEmpty {
                    out.append(TableRowData(isHeader: false, cells: cells))
                }
            }
        } else {
            let trNodes = tableNode.descendants { $0.key.lowercased() == "tr" }
            for tr in trNodes {
                let ths = tr.elements.filter { $0.key.lowercased() == "th" }.map(\.normalizedText)
                if !ths.isEmpty {
                    out.append(TableRowData(isHeader: true, cells: ths))
                } else {
                    let tds = tr.elements.filter { $0.key.lowercased() == "td" }.map(\.normalizedText)
                    if !tds.isEmpty {
                        out.append(TableRowData(isHeader: false, cells: tds))
                    }
                }
            }
        }
        return out
    }
}
