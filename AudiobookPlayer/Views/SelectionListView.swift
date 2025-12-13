import SwiftUI

/// Reusable selection list used by import flows (Baidu, Ebook, RSS).
struct SelectionList<Item: Identifiable, RowContent: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selectedIds: Set<Item.ID>
    let topContent: AnyView?
    let selectAllTitle: String
    let deselectAllTitle: String
    let summaryFormatter: (Int, Int) -> String
    let maxHeight: CGFloat
    let rowContent: (Item, Bool) -> RowContent

    private let indicatorWidth: CGFloat = 26
    private let indicatorContentSpacing: CGFloat = 12
    
    init(
        items: [Item],
        selectedIds: Binding<Set<Item.ID>>,
        topContent: (() -> AnyView)? = nil,
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
        self.topContent = topContent?()
        self.selectAllTitle = selectAllTitle
        self.deselectAllTitle = deselectAllTitle
        self.maxHeight = maxHeight
        self.summaryFormatter = summaryFormatter
        self.rowContent = rowContent
    }
    
    var body: some View {
        VStack(spacing: 12) {
            if let topContent {
                topContent
            }

            header
            
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        let isSelected = selectedIds.contains(item.id)
                        HStack(alignment: .top, spacing: indicatorContentSpacing) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .font(.system(size: 20))
                                .frame(width: indicatorWidth, height: 20, alignment: .center)

                            rowContent(item, isSelected)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleSelection(for: item.id)
                        }

                        Divider()
                            .padding(.leading, indicatorWidth + indicatorContentSpacing)
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
                selectedIds.formUnion(items.map(\.id))
            } label: {
                Text(selectAllTitle)
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Button {
                selectedIds.subtract(items.map(\.id))
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
