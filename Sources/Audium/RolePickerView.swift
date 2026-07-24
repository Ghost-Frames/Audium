import SwiftUI

/// Grouped/searchable Role picker (spec §8) — a stock SwiftUI `Picker` can't reasonably present
/// 395 items in one flat menu. Groups by `RoleLibrary.grouped`'s category sections inside a
/// popover, with a search field that filters name/summary/category across all of them at once.
struct RolePickerButton: View {
    @Binding var selection: Role?
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 4) {
                Text(selection?.name ?? "No role")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .help(selection?.summary ?? "No role selected — the assistant uses its default behavior.")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RolePickerContent(selection: $selection, isPresented: $isPresented)
        }
    }
}

private struct RolePickerContent: View {
    @Binding var selection: Role?
    @Binding var isPresented: Bool
    @State private var query = ""

    private var filteredGroups: [(category: String, roles: [Role])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return RoleLibrary.grouped }
        return RoleLibrary.grouped.compactMap { group in
            let matches = group.category.lowercased().contains(q)
                ? group.roles
                : group.roles.filter { $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
            return matches.isEmpty ? nil : (group.category, matches)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search \(RoleLibrary.all.count) roles…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .glassPanel(cornerRadius: 10)
            .padding(8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    noRoleRow
                    ForEach(filteredGroups, id: \.category) { group in
                        Section {
                            ForEach(group.roles) { role in
                                roleRow(role)
                            }
                        } header: {
                            sectionHeader(group.category)
                        }
                    }
                    if filteredGroups.isEmpty {
                        Text("No matching roles")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(12)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: 360, height: 440)
        .background(Theme.background)
    }

    private var noRoleRow: some View {
        Button {
            selection = nil
            isPresented = false
        } label: {
            HStack {
                Text("No role")
                Spacer()
                if selection == nil {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ category: String) -> some View {
        Text(category)
            .font(.caption.bold())
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
    }

    private func roleRow(_ role: Role) -> some View {
        Button {
            selection = role
            isPresented = false
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.name).font(.callout)
                    if let subcategory = role.subcategory {
                        Text(subcategory)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selection?.id == role.id {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(role.summary)
    }
}
