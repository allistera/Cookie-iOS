import SwiftUI

struct EmailRow: View {
    let email: DummyEmail

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(email.color)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(email.initial)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    HStack(spacing: 6) {
                        Text(email.sender)
                            .font(.subheadline.bold())
                        if email.isUnread {
                            Circle()
                                .fill(.blue)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Spacer()
                    Text(email.time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(email.subject)
                    .font(.subheadline.bold())
                    .lineLimit(1)

                Text(email.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
