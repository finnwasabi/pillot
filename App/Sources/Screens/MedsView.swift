import PillotCore
import SwiftUI

/// The list of medications. Each one has its own times, doses per day, maximum gap and pill count.
struct MedsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.editMedication) private var editMedication
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Half the cap height of the guide's body text, so a step number sits centred on the first line at any text size.
    @ScaledMetric(relativeTo: .body) private var halfCapHeight: CGFloat = 6

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Thuốc của bạn", "Your meds"))
                            .font(.largeTitle.weight(.black))
                            .foregroundStyle(Palette.text)
                        Text(L("Chạm vào một thuốc để sửa giờ, số lần uống hay số viên.", "Tap one to change its times, doses or pill count."))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .padding(.top, 12)
                    if model.medications.isEmpty { guideCard }
                    ForEach(model.medications) { medication in
                        Button { editMedication(medication) } label: { row(medication) }
                            .buttonStyle(PressableCardStyle())
                            .accessibilityHint(L("Sửa thuốc", "Edit medication"))
                    }
                    if model.medications.count < Medication.limit {
                        Button { editMedication(nil) } label: { Label(L("Thêm thuốc", "Add medication"), systemImage: "plus") }
                            .buttonStyle(NeoButtonStyle(fill: Palette.yellow))
                    } else {
                        Text(L("Tối đa \(Medication.limit) thuốc.", "Up to \(Medication.limit) medications."))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    if model.medications.count > 1 {
                        Label(L("Thuốc trùng giờ sẽ báo chung một chuông, bấm Đã uống là xong cả hai.", "Meds due at the same time share one alarm, and one tap on Taken covers them all."),
                              systemImage: "bell.badge.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                // A medication added or deleted slides in or out instead of popping.
                .animation(Motion.snappy(reduceMotion), value: model.medications.map(\.id))
            }
            .screenBackground()
        }
    }

    /// What the tab is for, shown until the first medication is added.
    private var guideCard: some View {
        let steps = [
            ("1", L("Thêm thuốc: tên, màu, biểu tượng và giờ uống theo giờ VN.", "Add a medication: name, color, icon and dose time in Vietnam time.")),
            ("2", L("Chọn số lần mỗi ngày, ngày nghỉ và số viên nếu muốn đếm.", "Pick doses a day, days off, and a pill count if you want one.")),
            ("3", L("Tới giờ app kêu như báo thức. Bấm Đã uống là xong.", "At dose time it rings like an alarm. Tap Taken and you are done.")),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            Text(L("Bắt đầu từ đây", "Start here"))
                .font(.title3.weight(.black))
            ForEach(steps, id: \.0) { number, text in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(number)
                        .font(.headline.weight(.black).monospacedDigit())
                        .frame(width: 30, height: 30)
                        .neo(Palette.surfaceOnFill, radius: 8, shadow: 0)
                        // Centre the box on the middle of the first line's capitals instead of sitting on its baseline.
                        .alignmentGuide(.firstTextBaseline) { [halfCapHeight] in $0[VerticalAlignment.center] + halfCapHeight }
                    Text(text)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(Palette.onFill)
        .card(Palette.lavender)
    }

    private func row(_ medication: Medication) -> some View {
        let now = Date.now
        return HStack(spacing: 14) {
            IconBadge(icon: medication.icon, fill: Palette.surfaceOnFill, size: 50)
            VStack(alignment: .leading, spacing: 4) {
                Text(medication.name)
                    .font(.title3.weight(.black))
                    .lineLimit(3)
                Text(medication.scheduleSummary)
                    .font(.subheadline.weight(.semibold))
                Text(medication.settings.asNeeded
                     ? L("Tối đa \(medication.settings.maxPerDay) lần mỗi ngày", "At most \(medication.settings.maxPerDay) a day")
                     : L("Cách nhau tối đa \(TodayText.duration(medication.settings.maxInterval))", "At most \(TodayText.duration(medication.settings.maxInterval)) apart"))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.onFillSecondary)
                HStack(spacing: 6) {
                    if let pills = medication.settings.pills {
                        tag(L("còn \(pills.remaining) viên", "\(pills.remaining) left"), icon: "pills")
                    }
                    if medication.settings.courseEnded(now: now) {
                        tag(L("xong liệu trình", "course done"), icon: "flag.checkered")
                    } else if medication.settings.pausedUntil(now: now) != nil {
                        tag(L("đang tạm dừng", "paused"), icon: "pause.fill")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.headline.weight(.black))
        }
        .foregroundStyle(Palette.onFill)
        .card(Swatch.color(medication.color))
    }

    private func tag(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .neo(Palette.surfaceOnFill, radius: 8, shadow: 0)
    }
}

/// A whole card that sinks into its shadow while pressed, like the buttons.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

/// Opens the medication editor: `nil` adds one. A single sheet at the root presents it for every screen, so a screen
/// that is swapped out by a tab change or redrawn by its timeline never owns a presentation (0.3.1: Add stopped
/// opening after the first sheet was closed).
struct EditMedicationAction {
    let open: (Medication?) -> Void
    func callAsFunction(_ medication: Medication?) { open(medication) }
}

extension EnvironmentValues {
    @Entry var editMedication = EditMedicationAction { _ in }
}

/// Adds or edits one medication. Changes apply on Save, except pausing, which applies right away.
struct MedicationEditor: View {
    /// `nil` adds a new medication.
    let medication: Medication?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = 0
    @State private var icon = Swatch.icons[0]
    @State private var time = VietnamClock.calendar.date(bySettingHour: 21, minute: 0, second: 0, of: .now)!
    @State private var dosesPerDay = 1
    @State private var gapHours = 24
    @State private var counting = false
    @State private var startCount = PillCounter.defaultPackSize
    @State private var packSize = PillCounter.defaultPackSize
    /// The remaining count as edited, and as it was when the editor opened. Save applies the difference, so a dose
    /// taken from an alarm while the editor is open is not undone.
    @State private var remaining = 0
    @State private var remainingAtOpen = 0
    @State private var cycleOn = false
    @State private var activeDays = 21
    @State private var breakDays = 7
    /// The first day on of the current pack, Vietnam date.
    @State private var cycleStart = Date.now
    @State private var asNeeded = false
    @State private var minGapHours = 4
    @State private var maxPerDay = 4
    @State private var pillsPerDose = 1
    @State private var hasEnd = false
    /// The last day of the course, Vietnam date.
    @State private var endDay = Date.now.addingTimeInterval(6 * 24 * 3600)
    @State private var refillEnabled = true
    @State private var refillAt = 7
    @State private var warning: ResetPreview?
    @State private var confirmDelete = false
    @State private var loaded = false
    @FocusState private var nameFocused: Bool

    private var live: Medication? { medication.flatMap { model.medication($0.id) } }
    private var period: Int { 24 / dosesPerDay }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview
                    section(L("Tên thuốc", "Name"), footer: L("Tên này hiện trên mọi lần nhắc.", "Shown on every reminder.")) {
                        NeoField(title: L("Ví dụ: Vitamin D", "For example: Vitamin D"), text: $name, limit: Medication.nameLimit)
                            .focused($nameFocused)
                    }
                    section(L("Màu và biểu tượng", "Color and icon")) { lookPicker }
                    section(L("Lịch uống", "Schedule"), footer: asNeeded ? asNeededFooter : scheduleFooter) { schedule }
                    if !asNeeded {
                        section(L("Ngày nghỉ", "Days off"), footer: L("Ví dụ vỉ 21 viên nghỉ 7 ngày. Ngày nghỉ không nhắc và không tính hụt.",
                                                                     "For example 21 days on and 7 off. Nothing rings and nothing counts as missed on days off.")) { cycle }
                        section(L("Liệu trình", "Course"), footer: L("Ví dụ kháng sinh 7 ngày. Sau ngày cuối app thôi nhắc, lịch sử vẫn giữ.",
                                                                    "For example 7 days of antibiotics. After the last day nothing rings; the history stays.")) { course }
                    }
                    section(L("Số viên", "Pills"), footer: counting ? nil : L("Tắt đếm thì app chỉ nhắc giờ.", "With counting off, the app only reminds you.")) { pills }
                    if let live { pauseSection(live) }
                    if let issue = model.dataIssue { Callout(text: issue, icon: "exclamationmark.octagon.fill") }
                    if medication != nil {
                        Button(L("Xoá thuốc này", "Delete this medication"), role: .destructive) { confirmDelete = true }
                            .buttonStyle(NeoButtonStyle(fill: Palette.coral, large: false))
                            // On the button, not the screen: since iOS 26 the dialog is a popover from the view it is attached to; on the screen it
                            // opened off to the side, and next to the file and alert presenters it did not open until something redrew the screen.
                            .confirmationDialog(L("Xoá \(trimmedName)?", "Delete \(trimmedName)?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                                Button(L("Xoá", "Delete"), role: .destructive) {
                                    if let medication, model.delete(medication.id) { dismiss() }
                                }
                            } message: {
                                Text(L("Lịch nhắc và lịch sử của thuốc này sẽ mất, không khôi phục được.", "Its reminders and history are deleted for good."))
                            }
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(medication == nil ? L("Thêm thuốc", "Add medication") : L("Sửa thuốc", "Edit medication"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The number pad has no return key.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L("Xong", "Done")) { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        .fontWeight(.heavy)
                }
                ToolbarItem(placement: .cancellationAction) { Button(L("Huỷ", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Lưu", "Save")) { save(confirmed: false) }
                        .fontWeight(.heavy)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .alert(L("Lần tới sẽ cách lần trước quá \(gapHours) giờ", "The next dose will be more than \(gapHours) h after the last one"),
                   isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button(L("Vẫn lưu", "Save anyway"), role: .destructive) { save(confirmed: true) }
                Button(L("Sửa lại", "Go back"), role: .cancel) { warning = nil }
            } message: {
                if let warning {
                    Text(L("Lần tới: \(TodayText.relativeDay(warning.dueAt, from: .now)) \(TimeFormatting.vn(warning.dueAt)). Xem tờ hướng dẫn thuốc trước khi giãn khoảng cách.",
                           "Next dose: \(TodayText.relativeDay(warning.dueAt, from: .now)) \(TimeFormatting.vn(warning.dueAt)). Check the leaflet before stretching the gap."))
                }
            }
        }
        .tint(Palette.ink)
        .onAppear(perform: load)
        .onChange(of: packSize) { old, new in if startCount == old { startCount = new } }
    }

    private var preview: some View {
        HStack(spacing: 14) {
            IconBadge(icon: icon, fill: Palette.surfaceOnFill, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(trimmedName.isEmpty ? L("Thuốc mới", "New medication") : trimmedName)
                    .font(.title2.weight(.black))
                    .lineLimit(3)
                Text(draftSummary)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Palette.onFill)
        .card(Swatch.color(color))
        .accessibilityElement(children: .combine)
    }

    private var draftSummary: String {
        var draft = Medication(name: name)
        let parts = VietnamClock.calendar.dateComponents([.hour, .minute], from: time)
        draft.settings = ReminderSettings(mainHour: parts.hour ?? 21, mainMinute: parts.minute ?? 0, dosesPerDay: dosesPerDay,
                                          pillsPerDose: pillsPerDose, asNeeded: asNeeded, minGap: TimeInterval(minGapHours * 3600))
        return draft.scheduleSummary
    }

    private var lookPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(Swatch.colors.indices, id: \.self) { index in
                    Button { color = index } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.black))
                            .foregroundStyle(Palette.onFill)
                            .opacity(color == index ? 1 : 0)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .neo(Swatch.colors[index], radius: 12, shadow: color == index ? 0 : 2.5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Màu \(index + 1)", "Color \(index + 1)"))
                    .accessibilityAddTraits(color == index ? .isSelected : [])
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Swatch.icons, id: \.self) { symbol in
                    Button { icon = symbol } label: {
                        Image(systemName: symbol)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(icon == symbol ? Palette.onFill : Palette.text)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .neo(icon == symbol ? Palette.yellow : Palette.surface, radius: 12, shadow: icon == symbol ? 0 : 2.5)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol)
                    .accessibilityAddTraits(icon == symbol ? .isSelected : [])
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(L("Uống khi cần, không có lịch", "Only when needed, no schedule"), isOn: $asNeeded)
                .toggleStyle(NeoToggleStyle())
            InkDivider()
            NeoRow(title: L("Mỗi lần uống", "Each dose"), detail: L("số viên trừ đi khi đếm", "pills subtracted when counting")) {
                NeoStepper(value: $pillsPerDose, range: ReminderSettings.pillsPerDoseRange, unit: L("viên", "pills"))
            }
            InkDivider()
            if asNeeded { asNeededRows } else { timedRows }
        }
    }

    /// The warnings a medication taken when needed has instead of a schedule.
    private var asNeededRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            NeoRow(title: L("Cách nhau ít nhất", "At least apart"), detail: L("app nhắc nếu uống sớm hơn", "the app warns when sooner")) {
                NeoStepper(value: $minGapHours, range: 1...24, unit: L("giờ", "h"))
            }
            NeoRow(title: L("Tối đa mỗi ngày", "At most a day")) {
                NeoStepper(value: $maxPerDay, range: 1...12, unit: L("lần", "times"))
            }
        }
    }

    private var asNeededFooter: String {
        L("Không có báo thức và không tính hụt. Bấm Đã uống mỗi khi uống; app chỉ nhắc khi chưa đủ \(minGapHours) giờ từ lần trước hoặc đã quá \(maxPerDay) lần trong ngày. Bao nhiêu là đủ: theo tờ hướng dẫn hoặc bác sĩ.",
          "No alarms and nothing counts as missed. Tap Taken whenever you take it; the app only warns when it has been less than \(minGapHours) h or more than \(maxPerDay) times today. How much is right: the leaflet or your doctor.")
    }

    private var course: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(L("Có ngày kết thúc", "Has an end date"), isOn: $hasEnd)
                .toggleStyle(NeoToggleStyle())
            if hasEnd {
                InkDivider()
                NeoRow(title: L("Ngày uống cuối", "Last day"), detail: L("giờ VN", "VN time")) {
                    DatePicker("", selection: $endDay, in: Date.now.addingTimeInterval(-30 * 24 * 3600)..., displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.timeZone, VietnamClock.timeZone)
                }
            }
        }
    }

    private var timedRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            NeoRow(title: dosesPerDay == 1 ? L("Giờ uống", "Dose time") : L("Lần đầu trong ngày", "First dose"), detail: L("giờ VN", "VN time")) {
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.timeZone, VietnamClock.timeZone)
            }
            InkDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Số lần mỗi ngày", "Doses a day"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.text)
                NeoSegmented(options: ReminderSettings.allowedDosesPerDay.map { ($0, "\($0)×") }, selection: Binding(
                    get: { dosesPerDay },
                    set: { value in
                        dosesPerDay = value
                        gapHours = 24 / value
                    }))
                Text(L("Uống lúc \(draftTimes)", "At \(draftTimes)"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
            InkDivider()
            // The gap cannot be shorter than the time between two doses, or every dose would drift earlier.
            NeoRow(title: L("Cách nhau tối đa", "Max gap"), detail: L("từ \(period) tới \(period * 2) giờ", "\(period) to \(period * 2) h")) {
                NeoStepper(value: $gapHours, range: period...(period * 2), unit: L("giờ", "h"))
            }
        }
    }

    private var cycle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(L("Có ngày nghỉ theo chu kỳ", "Days off in a cycle"), isOn: $cycleOn)
                .toggleStyle(NeoToggleStyle())
            if cycleOn {
                InkDivider()
                NeoRow(title: L("Uống", "Days on")) {
                    NeoStepper(value: $activeDays, range: 1...90, unit: L("ngày", "days"), editable: true)
                }
                NeoRow(title: L("Nghỉ", "Days off")) {
                    NeoStepper(value: $breakDays, range: 1...30, unit: L("ngày", "days"), editable: true)
                }
                NeoRow(title: L("Ngày uống đầu tiên", "First day on"), detail: L("của vỉ hoặc chu kỳ hiện tại", "of the current pack or cycle")) {
                    DatePicker("", selection: $cycleStart, displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.timeZone, VietnamClock.timeZone)
                }
                Text(cycleSummary)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// "Hôm nay là ngày 5/28: ngày uống." or the end of the days off.
    private var cycleSummary: String {
        let c = DoseCycle(activeDays: activeDays, breakDays: breakDays, startDay: cycleStart)
        let calendar = VietnamClock.calendar
        let days = calendar.dateComponents([.day], from: c.startDay, to: calendar.startOfDay(for: .now)).day ?? 0
        guard days >= 0 else { return L("Chu kỳ bắt đầu \(TodayText.dayTitle(c.startDay)).", "The cycle starts \(TodayText.dayTitle(c.startDay)).") }
        let length = activeDays + breakDays
        if let end = c.breakEnd(after: .now) {
            return L("Hôm nay là ngày \(days % length + 1)/\(length): nghỉ, uống lại từ \(TodayText.dayTitle(end)).",
                     "Today is day \(days % length + 1) of \(length): a day off, doses start again \(TodayText.dayTitle(end)).")
        }
        return L("Hôm nay là ngày \(days % length + 1)/\(length): ngày uống.", "Today is day \(days % length + 1) of \(length): a day on.")
    }

    private var draftTimes: String {
        var draft = Medication(name: "")
        let parts = VietnamClock.calendar.dateComponents([.hour, .minute], from: time)
        draft.settings = ReminderSettings(mainHour: parts.hour ?? 21, mainMinute: parts.minute ?? 0, dosesPerDay: dosesPerDay)
        return draft.doseTimes.joined(separator: " · ")
    }

    /// Why the gap stops at the time between two doses, with the way to get a shorter one.
    private var scheduleFooter: String {
        let shorter = ReminderSettings.allowedDosesPerDay.contains(dosesPerDay * 2)
            ? L(" Muốn nhắc dày hơn, ví dụ mỗi \(period / 2) giờ, thì tăng số lần mỗi ngày.", " For closer doses, say every \(period / 2) h, raise the doses a day.")
            : ""
        return L("Luôn theo giờ Việt Nam. Quá \(gapHours) giờ mà chưa uống thì báo thức kêu dồn và tính trễ; uống sớm thì lần sau nhắc sớm theo. Ngắn nhất là \(period) giờ, bằng khoảng giữa hai lần uống, vì ngắn hơn thì mỗi lần sẽ kéo lần sau sớm dần.\(shorter)",
                 "Always Vietnam time. After \(gapHours) h without a dose, the alarms ring harder and the dose counts as late. Taking it early moves the next reminder earlier. The shortest is \(period) h, the time between two doses, since anything shorter would pull every dose a little earlier.\(shorter)")
    }

    @ViewBuilder
    private var pills: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(L("Đếm số viên", "Count pills"), isOn: $counting)
                .toggleStyle(NeoToggleStyle())
            if counting {
                InkDivider()
                NeoRow(title: L("Mỗi vỉ có", "Pills per pack"), detail: L("dùng cho nút thêm 1 vỉ", "used by Add a pack")) {
                    NeoStepper(value: $packSize, range: 1...200, unit: L("viên", "pills"), editable: true)
                }
                if live?.settings.pills != nil {
                    NeoRow(title: L("Còn lại", "Remaining"), detail: L("gõ số hoặc giữ nút để chỉnh nhanh", "type it, or hold a button")) {
                        NeoStepper(value: $remaining, range: 0...999, unit: L("viên", "pills"), editable: true)
                    }
                    Button { remaining = min(999, remaining + packSize) } label: {
                        Label(L("Thêm 1 vỉ (\(packSize) viên)", "Add a pack (\(packSize) pills)"), systemImage: "plus")
                    }
                    .buttonStyle(ChipButtonStyle(fill: Palette.mint))
                    if remaining != remainingAtOpen {
                        Text(remaining > remainingAtOpen
                             ? L("Lưu để thêm \(remaining - remainingAtOpen) viên.", "Save to add \(remaining - remainingAtOpen) pills.")
                             : L("Lưu để bớt \(remainingAtOpen - remaining) viên.", "Save to remove \(remainingAtOpen - remaining) pills."))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    NeoRow(title: L("Đang có", "You have"), detail: L("mỗi lần uống trừ một viên", "each dose subtracts one")) {
                        NeoStepper(value: $startCount, range: 1...999, unit: L("viên", "pills"), editable: true)
                    }
                }
                InkDivider()
                Toggle(L("Nhắc mua thêm", "Refill reminder"), isOn: $refillEnabled)
                    .toggleStyle(NeoToggleStyle())
                if refillEnabled {
                    NeoRow(title: L("Nhắc khi còn", "Remind at")) {
                        NeoStepper(value: $refillAt, range: 1...60, unit: L("viên", "pills"), editable: true)
                    }
                }
            } else if live?.settings.pills != nil {
                Callout(text: L("Lưu thì số viên đang đếm sẽ mất. Lịch sử uống vẫn giữ.", "Saving drops the current pill count. Your history stays."),
                        icon: "exclamationmark.triangle.fill", fill: Palette.yellow)
            }
        }
    }

    private func pauseSection(_ live: Medication) -> some View {
        section(L("Tạm dừng", "Pause"), footer: L("Trong lúc tạm dừng không nhắc và không tính hụt. Áp dụng ngay, không cần bấm Lưu.",
                                                 "No reminders and no misses during a pause. Applies right away, no need to save.")) {
            if let until = live.settings.pausedUntil(now: .now) {
                NeoRow(title: L("Đang tạm dừng tới", "Paused until"), detail: "\(TodayText.dayTitle(until)), \(TimeFormatting.vn(until))") {
                    Button(L("Nhắc lại ngay", "Resume")) { model.update(live.id) { $0.planner.resume(now: .now) } }
                        .buttonStyle(ChipButtonStyle(fill: Palette.mint))
                }
            } else {
                HStack(spacing: 10) {
                    ForEach([1, 3, 7], id: \.self) { days in
                        Button(L("\(days) ngày", days == 1 ? "1 day" : "\(days) days")) { model.update(live.id, stopsAlarms: true) { $0.planner.pause(days: days, now: .now) } }
                            .buttonStyle(ChipButtonStyle())
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline.weight(.black))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)
            content()
                .card()
            if let footer {
                Text(footer)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let medication else {
            color = model.nextColor
            // A new medication starts with its name. After the sheet has slid in, or the keyboard fights the animation.
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                nameFocused = true
            }
            return
        }
        let s = medication.settings
        name = medication.name
        color = medication.color
        icon = medication.icon
        time = VietnamClock.calendar.date(bySettingHour: s.mainHour, minute: s.mainMinute, second: 0, of: .now)!
        dosesPerDay = s.dosesPerDay
        gapHours = Int((s.maxInterval / 3600).rounded())
        counting = s.pills != nil
        if let c = s.cycle {
            cycleOn = true
            activeDays = c.activeDays
            breakDays = c.breakDays
            cycleStart = c.startDay
        }
        if let pills = s.pills {
            packSize = pills.pack
            startCount = pills.pack
            remaining = pills.remaining
            remainingAtOpen = pills.remaining
        }
        refillEnabled = s.refillReminder.enabled
        refillAt = s.refillReminder.daysBefore
        asNeeded = s.asNeeded
        minGapHours = max(1, Int((s.minGap / 3600).rounded()))
        maxPerDay = s.maxPerDay
        pillsPerDose = s.pillsPerDose
        if let end = s.endDay {
            hasEnd = true
            endDay = end
        }
    }

    private func save(confirmed: Bool) {
        let parts = VietnamClock.calendar.dateComponents([.hour, .minute], from: time)
        let hour = parts.hour ?? 21, minute = parts.minute ?? 0
        let now = Date.now
        let refill = RefillReminder(enabled: refillEnabled, daysBefore: refillAt)
        let cycleValue = cycleOn ? DoseCycle(activeDays: activeDays, breakDays: breakDays, startDay: cycleStart) : nil
        let endValue = hasEnd ? VietnamClock.startOfDay(endDay) : nil
        func apply(_ medication: inout Medication) {
            medication.name = String(trimmedName.prefix(Medication.nameLimit))
            medication.color = color
            medication.icon = icon
            let s = medication.settings
            if s.mainHour != hour || s.mainMinute != minute || s.dosesPerDay != dosesPerDay {
                medication.planner.changeSchedule(hour: hour, minute: minute, dosesPerDay: dosesPerDay, now: now)
            }
            let range = medication.settings.maxIntervalRange
            medication.settings.maxInterval = min(max(TimeInterval(gapHours * 3600), range.lowerBound), range.upperBound)
            if !counting {
                medication.settings.pills = nil
            } else if medication.settings.pills == nil {
                medication.settings.pills = PillCounter(count: startCount, at: now, packSize: packSize)
            } else {
                if remaining != remainingAtOpen, let current = medication.settings.pills?.remaining {
                    medication.settings.pills?.setRemaining(current + remaining - remainingAtOpen, at: now)
                }
                medication.settings.pills?.packSize = packSize
            }
            medication.settings.refillReminder = refill
            medication.settings.cycle = cycleValue
            medication.settings.endDay = endValue
            medication.settings.asNeeded = asNeeded
            medication.settings.minGap = TimeInterval(minGapHours * 3600)
            medication.settings.maxPerDay = maxPerDay
            medication.settings.pillsPerDose = pillsPerDose
        }
        if let live {
            let s = live.settings
            let timing = s.mainHour != hour || s.mainMinute != minute || s.dosesPerDay != dosesPerDay || Int((s.maxInterval / 3600).rounded()) != gapHours
            // Anything that changes which doses were due also re-reads the past, so the past is frozen first.
            let reschedules = timing || s.asNeeded != asNeeded || s.cycle != cycleValue || s.endDay != endValue
            func applyEdit(_ medication: inout Medication) {
                if reschedules { medication.planner.freezeHistory(now: now) }
                apply(&medication)
            }
            if !confirmed && timing {
                var copy = live
                applyEdit(&copy)
                let dose = copy.planner.currentDose(now: now)
                if dose.exceedsMaxInterval {
                    warning = ResetPreview(dueAt: dose.dueAt, deadlineAt: dose.deadlineAt, exceedsMaxInterval: true)
                    return
                }
            }
            guard model.update(live.id, stopsAlarms: reschedules, applyEdit) else { return }
        } else if medication == nil {
            var medication = Medication(name: trimmedName, color: color, icon: icon,
                                        settings: ReminderSettings(mainHour: hour, mainMinute: minute, dosesPerDay: dosesPerDay))
            apply(&medication)
            guard model.add(medication) else { return }
        }
        // An existing medication deleted while its editor was open is not brought back.
        dismiss()
    }
}

#Preview { MedsView().environment(AppModel.shared) }
