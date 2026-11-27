import AlarmKit
import SwiftUI

// Explains why alarm permission is needed, then asks for it.
struct OnboardingView: View {
    var onFinish: () -> Void

    @Environment(AppModel.self) private var model
    @State private var asking = false

    var body: some View {
        FullScreenScroll {
            VStack(spacing: 24) {
                Spacer()
                IconBadge(icon: "alarm.fill", fill: Palette.pink, size: 112)
                    .rotationEffect(.degrees(-4))
                VStack(spacing: 12) {
                    Text(L("Nhắc uống thuốc đúng giờ", "Take your meds on time"))
                        .font(.largeTitle.weight(.black))
                        .foregroundStyle(Palette.text)
                        .multilineTextAlignment(.center)
                    Text(L("Pillot đặt báo thức theo giờ Việt Nam, kêu cả khi máy đang im lặng hay bật Focus.", "Pillot sets alarms on Vietnam time that ring even when the phone is on silent or in Focus."))
                        .font(.body)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 14) {
                    point(icon: "globe.asia.australia.fill", text: L("Bay đi đâu cũng nhắc đúng giờ VN", "On Vietnam time wherever you fly"))
                    point(icon: "bell.and.waves.left.and.right.fill", text: L("Nhắc lại tới khi bạn bấm Đã uống", "Keeps reminding until you tap Taken"))
                    point(icon: "airplane", text: L("Không cần mạng, chế độ máy bay vẫn nhắc", "No internet needed, works in airplane mode"))
                }
                .foregroundStyle(Palette.onFill)
                .card(Palette.yellow)
                Spacer()
                Button(L("Cho phép báo thức", "Allow alarms")) {
                    asking = true
                    Task {
                        // Declining still lets the user in; Today then shows the scheduling warning.
                        _ = try? await AlarmManager.shared.requestAuthorization()
                        await model.checkNotifications(onboarding: true)
                        await model.resync()
                        onFinish()
                    }
                }
                .buttonStyle(NeoButtonStyle())
                .disabled(asking)
                Text(L("Máy sẽ hỏi hai lần: báo thức và thông báo.", "Your phone asks twice: alarms and notifications."))
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .screenBackground()
    }

    private func point(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.bold))
                .frame(width: 28)
            Text(text)
                .font(.body.weight(.semibold))
        }
    }
}

#Preview { OnboardingView {}.environment(AppModel.shared) }
