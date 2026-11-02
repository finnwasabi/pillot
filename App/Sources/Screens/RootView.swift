import PillotCore
import SwiftUI

struct RootView: View {
    /// Opens on this tab (screenshots). `nil` keeps the last one.
    var selectedTab: Int?

    // SceneStorage keeps the tab when a language change rebuilds the tree.
    @SceneStorage("tab") private var tab = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Taps per tab, to bounce the icon that was tapped.
    @State private var taps = [0, 0, 0, 0]
    @State private var editor: EditorRequest?
    @Environment(AppModel.self) private var model

    /// One request per tap, so opening the same medication twice still presents.
    private struct EditorRequest: Identifiable {
        let id = UUID()
        let medication: Medication?
    }

    private var tabs: [(title: String, icon: String)] {
        [(L("Hôm nay", "Today"), "sun.max.fill"), (L("Thuốc", "Meds"), "pills.fill"),
         (L("Lịch sử", "History"), "calendar"), (L("Cài đặt", "Settings"), "gearshape.fill")]
    }

    var body: some View {
        // A ZStack, not a Group: modifiers on a Group are copied onto each screen, so every tab carried its own tab
        // bar, sheet and onAppear, and the bar flashed in with the screen on every switch (0.3.2).
        ZStack {
            Group {
                switch tab {
                case 1: MedsView()
                case 2: HistoryView()
                case 3: SettingsView()
                default: TodayView()
                }
            }
            // The new screen fades in over the old one, which leaves at once: one screen drawn per frame, no crossfade of two.
            .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)), removal: .identity))
        }
        // The screens have no NavigationStack of their own: one would swallow this inset, and the end of every
        // list would stay hidden under the bar (0.2.0 on a 6.1 inch phone).
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
        .sheet(item: $editor) { MedicationEditor(medication: $0.medication) }
        .environment(\.editMedication, EditMedicationAction { editor = EditorRequest(medication: $0) })
        .onAppear { if let selectedTab { tab = selectedTab } }
        // Here at the root, not on a card: the question must survive tab changes (see the Add medication fix in 0.3.2).
        .alert(L("Đã uống \(model.takenQuestion?.names ?? "")?", "Taken \(model.takenQuestion?.names ?? "")?"),
               isPresented: Binding(get: { model.takenQuestion != nil }, set: { if !$0 { model.takenQuestion = nil } }),
               presenting: model.takenQuestion) { question in
            Button(L("Đã uống", "Taken")) {
                guard !question.ids.isEmpty else { return }
                Task { await model.markTaken(question.ids) }
            }
            Button(L("Chưa", "Not yet"), role: .cancel) {}
        } message: { _ in
            Text(L("Chưa uống thì lát nữa báo thức kêu lại.", "If not, the alarm rings again soon."))
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs.indices, id: \.self) { index in
                let selected = tab == index
                Button {
                    taps[index] += 1
                    guard tab != index else { return }
                    withAnimation(Motion.snappy(reduceMotion)) { tab = index }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tabs[index].icon)
                            .font(.system(size: 18, weight: .bold))
                            .symbolEffect(.bounce, value: taps[index])
                        Text(tabs[index].title)
                            .font(.caption2.weight(.heavy))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(selected ? Palette.onFill : Palette.text)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        // One pill behind every label that slides to the selected tab. A pill per tab would fade out on top of the
        // next tab's label while sliding.
        .background { SlidingPill(index: tab, count: tabs.count, spacing: 4, radius: 12, lineWidth: 2) }
        .padding(6)
        .neo(Palette.surface, radius: 20)
        // Four labels in a fixed bar cannot grow forever.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .screenBackground()
        .sensoryFeedback(.selection, trigger: tab)
    }
}
