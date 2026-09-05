import SwiftUI

struct InboxToolbar: View {
    @Binding var selectedFilter: EmailFilter?
    @Binding var searchText: String
    let isSearching: Bool
    var onSubmit: () -> Void
    var onSearchChange: () -> Void
    var onClear: () -> Void
    var onCompose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Filter", selection: $selectedFilter) {
                    Text("All emails")
                        .tag(EmailFilter?.none)

                    ForEach(EmailFilter.allCases) { filter in
                        Text(filter.rawValue)
                            .tag(Optional(filter))
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Filter emails")

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField("Search emails...", text: $searchText)
                    .foregroundStyle(.primary)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        onSubmit()
                    }
                    .onChange(of: searchText) {
                        onSearchChange()
                    }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                // Independent of the spinner so a slow search can still be
                // abandoned, like the web bar's always-present close icon.
                if !searchText.isEmpty {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(.ultraThinMaterial, in: Capsule())

            Button {
                onCompose()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Compose email")
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
