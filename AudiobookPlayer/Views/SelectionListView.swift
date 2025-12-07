import SwiftUI

/// Reusable selection list used by import flows (Baidu, Ebook, RSS).
struct SelectionList<Item: Identifiable, RowContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selectedIds: Set<Item.ID>
    let selectAllTitle: String
    let deselectAllTitle: String
    let summaryFormatter: (Int, Int) -> String
    let maxHeight: CGFloat
    let rowContent: (Item, Bool) -> RowContent
    
    init(
        items: [Item],
        selectedIds: Binding<Set<Item.ID>>,
        selectAllTitle: String = NSLocalizedString("select_all_button", value: "Select All", comment: "Select all items"),
        deselectAllTitle: String = NSLocalizedString("deselect_all_button", value: "Deselect All", comment: "Deselect all items"),
        maxHeight: CGFloat = 320,
        summaryFormatter: @escaping (Int, Int) -> String = { selected, total in
            "\(selected) of \(total)"
        },
        rowContent: @escaping (Item, Bool) -> RowContent
    ) {
        self.items = items
        self._selectedIds = selectedIds
        self.selectAllTitle = selectAllTitle
        self.deselectAllTitle = deselectAllTitle
        self.maxHeight = maxHeight
        self.summaryFormatter = summaryFormatter
        self.rowContent = rowContent
    }
    
    var body: some View {
        VStack(spacing: 12) {
            header
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        let isSelected = selectedIds.contains(item.id)
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .foregroundColor(isSelected ? .blue : .gray)
                            
                            rowContent(item, isSelected)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleSelection(for: item.id)
                        }
                        
                        Divider()
                            .padding(.leading, 32)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: maxHeight)
        }
    }
    
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                selectedIds = Set(items.map(\.id))
            } label: {
                Text(selectAllTitle)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Button {
                selectedIds.removeAll()
            } label: {
                Text(deselectAllTitle)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Text(summaryFormatter(selectedIds.count, items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    
    private func toggleSelection(for id: Item.ID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }
}
