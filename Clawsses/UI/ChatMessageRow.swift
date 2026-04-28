import SwiftUI

struct ChatMessageRow: View {
    let msg: ChatMessage

    var body: some View {
        HStack {
            if msg.role == "user" { Spacer(minLength: 40) }
            Text(msg.content)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(msg.role == "user" ? Color(red: 0.31, green: 0.79, blue: 0.69) : Color(red: 0.83, green: 0.83, blue: 0.83))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(msg.role == "user" ? Color(red: 0.16, green: 0.23, blue: 0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
            if msg.role == "assistant" { Spacer(minLength: 40) }
        }
        .padding(.vertical, 1)
    }
}
