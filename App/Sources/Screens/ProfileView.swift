import SwiftUI

/// First launch, after the language: asks for the user's name, then offers to add a partner (skippable).
struct ProfileView: View {
    var onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var name = ""
    @State private var partner = ""
    @State private var code = ""
    @State private var connectionIssue: String?
    @FocusState private var focused: Bool

    var body: some View {
        FullScreenScroll {
            VStack(spacing: 24) {
                Spacer()
                IconBadge(icon: step == 0 ? "face.smiling.inverse" : "heart.fill", fill: step == 0 ? Palette.yellow : Palette.pink, size: 112)
                    .rotationEffect(.degrees(step == 0 ? -4 : 4))
                if step == 0 { nameStep } else { partnerStep }
                Spacer()
                buttons
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .screenBackground()
        .onAppear { focused = true }
    }

    private var nameStep: some View {
        VStack(spacing: 12) {
            Text(L("Bạn tên gì?", "What's your name?"))
                .font(.largeTitle.weight(.black))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(L("App dùng tên này để chào bạn.", "The app uses it to greet you."))
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            field(L("Tên bạn", "Your name"), text: $name)
                .textContentType(.givenName)
                .focused($focused)
                .submitLabel(.next)
                .onSubmit(next)
        }
    }

    private var partnerStep: some View {
        VStack(spacing: 12) {
            Text(L("Thêm partner theo dõi cùng?", "Add a partner to follow along?"))
                .font(.largeTitle.weight(.black))
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
            Text(L("Partner xem được bạn đã uống thuốc chưa qua Telegram và gửi lời nhắn vào app. Để sau cũng được, trong Cài đặt.",
                   "Your partner can see on Telegram whether you have taken your meds and send you messages in the app. You can also do this later in Settings."))
                .font(.body.weight(.medium))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            field(L("Tên partner", "Partner's name"), text: $partner)
                .focused($focused)
            field(L("Mã kết nối partner gửi (nếu có)", "Connection code from your partner (if any)"), text: $code, limit: 500)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let connectionIssue {
                Text(connectionIssue)
                    .font(.footnote)
                    .foregroundStyle(Palette.text)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, limit: Int = AppModel.nameLimit) -> some View {
        NeoField(title: title, text: text, limit: limit)
    }

    @ViewBuilder
    private var buttons: some View {
        if step == 0 {
            Button(L("Tiếp tục", "Continue"), action: next)
                .buttonStyle(NeoButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        } else {
            Button(L("Lưu", "Save")) {
                do {
                    if !code.isEmpty { try model.connect(code: code) }
                    model.partnerName = partner.trimmingCharacters(in: .whitespaces)
                    onFinish()
                } catch {
                    connectionIssue = error.localizedDescription
                }
            }
            .buttonStyle(NeoButtonStyle())
            .disabled(partner.trimmingCharacters(in: .whitespaces).isEmpty && code.isEmpty)
            Button(L("Bỏ qua", "Skip"), action: onFinish)
                .buttonStyle(NeoButtonStyle(fill: Palette.surfaceOnFill, large: false))
        }
    }

    private func next() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.userName = trimmed
        step = 1
        focused = true
    }
}

#Preview { ProfileView {}.environment(AppModel.shared) }
