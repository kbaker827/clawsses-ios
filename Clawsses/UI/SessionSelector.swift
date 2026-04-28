import SwiftUI

struct SessionSelector: View {
    let sessions: [SessionInfo]
    let currentSessionKey: String?
    let unreadSessionKeys: Set<String>
    @Binding var expanded: Bool
    let onToggle: () -> Void
    let onSelect: (SessionInfo) -> Void

    private var currentSession: SessionInfo? {
        sessions.first(where: { $0.key == currentSessionKey })
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(unreadSessionKeys.isEmpty ? .accentColor : .green)
                    Text(currentSession?.name ?? currentSessionKey ?? "No session")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    if !unreadSessionKeys.isEmpty {
                        Circle().fill(.green).frame(width: 8, height: 8)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                if sessions.isEmpty {
                    Text("Loading sessions...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(sessions) { session in
                        Button {
                            onSelect(session)
                            expanded = false
                        } label: {
                            HStack {
                                if session.key == currentSessionKey {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.accentColor)
                                        .font(.caption)
                                } else if unreadSessionKeys.contains(session.key) {
                                    Circle().fill(.green).frame(width: 8, height: 8)
                                } else {
                                    Spacer().frame(width: 16)
                                }
                                Text(session.name)
                                    .foregroundStyle(session.key == currentSessionKey ? .accentColor :
                                                     unreadSessionKeys.contains(session.key) ? .green : .primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }
}
