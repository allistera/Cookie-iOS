import SwiftUI

struct InboxHeader: View {
    @Binding var selectedSection: AppSection
    let unreadCount: Int
    let avatarInitial: String
    var onAccount: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            Menu {
                Picker("Section", selection: $selectedSection) {
                    ForEach(AppSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedSection.icon)
                        .font(.title2)
                        .foregroundStyle(.red)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(selectedSection.rawValue)
                            .font(.largeTitle.bold())
                            .foregroundStyle(.primary)
                        if selectedSection == .email, unreadCount > 0 {
                            Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityLabel("Switch section, currently \(selectedSection.rawValue)")

            Spacer()

            Button {
                onAccount()
            } label: {
                Circle()
                    .fill(Color(red: 0.72, green: 0.29, blue: 0.15))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(avatarInitial)
                            .font(.headline)
                            .foregroundStyle(.white)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

}
