/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import SwiftUI

enum LiveEarningsAmountColor {
    static let defaultHex = "#30D158"

    static func color(from storedHex: String?) -> Color {
        let hex = (storedHex ?? defaultHex)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else {
            return color(from: defaultHex)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func hex(from color: Color) -> String {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else {
            return defaultHex
        }
        let red = Int((min(max(converted.redComponent, 0), 1) * 255).rounded())
        let green = Int((min(max(converted.greenComponent, 0), 1) * 255).rounded())
        let blue = Int((min(max(converted.blueComponent, 0), 1) * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

enum LiveEarningsLayout {
    /// Equal, compact wings keep the physical camera housing centered. The
    /// amount scales inside this fixed width instead of growing the window
    /// into menu-bar items or relying on content drawn beyond the clip bounds.
    static let closedWingWidth: CGFloat = 38
    static let closedAmountHorizontalInset: CGFloat = 1

    /// Keeps expanded Home controls clear of the screen's top edge while the
    /// outer notch remains physically attached to the display bezel.
    static let expandedHomeTopInset: CGFloat = 8
}

private enum LiveEarningsPresentedSheet: String, Identifiable {
    case history
    case workCalendar

    var id: Self { self }
}

struct LiveEarningsClosedAmountView: View {
    @ObservedObject private var controller = LiveEarningsController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(controller.formattedAmountWithoutSymbol)
            .font(.system(size: adaptiveFontSize, weight: .semibold, design: .rounded))
            .fontWidth(.compressed)
            .foregroundStyle(LiveEarningsAmountColor.color(from: controller.config.closedAmountColorHex))
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.55)
            .contentTransition(.numericText(countsDown: false))
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: controller.snapshot.earnedAmount)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, LiveEarningsLayout.closedAmountHorizontalInset)
            .clipped()
            .accessibilityLabel(LiveEarningsL10n.earnedToday)
            .accessibilityValue(controller.formattedAmountWithCurrency)
    }

    private var adaptiveFontSize: CGFloat {
        switch controller.closedAmountIntegerDigitCount {
        case ...2: return 14
        case 3: return 13
        case 4: return 12
        case 5: return 10.5
        default: return 9.5
        }
    }
}

struct LiveEarningsHomeCard: View {
    @ObservedObject private var controller = LiveEarningsController.shared
    @EnvironmentObject private var notchViewModel: DynamicIslandViewModel
    @State private var presentedSheet: LiveEarningsPresentedSheet?
    @State private var autoCloseSuppressionToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(LiveEarningsL10n.liveEarnings, systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                Text(LiveEarningsL10n.status(controller.snapshot.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if controller.config.privacyModeEnabled {
                Label(LiveEarningsL10n.hiddenInPrivacyMode, systemImage: "eye.slash.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else if isNonEarningDay {
                Label(nonEarningDescription, systemImage: nonEarningIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                Text(controller.formattedAmountWithCurrency)
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.smooth(duration: 0.25), value: controller.snapshot.earnedAmount)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
            }

            if !isNonEarningDay {
                ProgressView(value: controller.snapshot.progress)
                    .progressViewStyle(
                        LinearProgressViewStyle(
                            tint: LiveEarningsAmountColor.color(from: LiveEarningsAmountColor.defaultHex)
                        )
                    )
            }

            if !isNonEarningDay {
                HStack {
                    Text(LiveEarningsL10n.earnedToday)
                    Spacer()
                    Text("\(Int((controller.snapshot.progress * 100).rounded()))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    present(.history)
                } label: {
                    Label(String(localized: "History"), systemImage: "clock.arrow.circlepath")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.medium))
        }
        .padding(14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .sheet(item: $presentedSheet, onDismiss: releaseAutoCloseSuppression) { sheet in
            switch sheet {
            case .history:
                LiveEarningsHistoryView()
            case .workCalendar:
                WorkCalendarView()
            }
        }
        .onDisappear(perform: releaseAutoCloseSuppression)
    }

    private func present(_ sheet: LiveEarningsPresentedSheet) {
        // A sheet launched from Home moves the pointer outside the notch. Keep
        // the notch open before presentation so its view hierarchy cannot be
        // torn down underneath the sheet and trigger a dismiss/re-present loop.
        notchViewModel.setAutoCloseSuppression(true, token: autoCloseSuppressionToken)
        presentedSheet = sheet
    }

    private func releaseAutoCloseSuppression() {
        notchViewModel.setAutoCloseSuppression(false, token: autoCloseSuppressionToken)
        notchViewModel.shouldRecheckHover.toggle()
    }

    private var isNonEarningDay: Bool {
        [.restDay, .publicHoliday, .leaveDay].contains(controller.snapshot.status)
    }

    private var nonEarningDescription: String {
        switch controller.snapshot.status {
        case .leaveDay: String(localized: "Leave day · Earnings are paused")
        case .publicHoliday: String(localized: "Public holiday · No earnings today")
        default: String(localized: "Rest day · No earnings today")
        }
    }

    private var nonEarningIcon: String {
        switch controller.snapshot.status {
        case .leaveDay: "person.crop.circle.badge.clock"
        case .publicHoliday: "calendar.badge.minus"
        default: "moon.zzz.fill"
        }
    }
}

struct LiveEarningsSettingsView: View {
    @ObservedObject private var controller = LiveEarningsController.shared
    @State private var draft = LiveEarningsConfig()
    @State private var didLoad = false
    @State private var presentedSheet: LiveEarningsPresentedSheet?

    var body: some View {
        Form {
            Section {
                Toggle(LiveEarningsL10n.enable, isOn: $draft.isEnabled)
            }

            Section {
                LiveEarningsSalaryFields(config: $draft)
            } header: {
                Text(LiveEarningsL10n.salaryType)
            }

            Section {
                LiveEarningsWorkScheduleFields(config: $draft)
            } header: {
                Text(LiveEarningsL10n.workSchedule)
            }

            Section(String(localized: "Work calendar and history")) {
                Button {
                    presentedSheet = .workCalendar
                } label: {
                    Label(String(localized: "Manage work calendar"), systemImage: "calendar.badge.clock")
                }
                Button {
                    presentedSheet = .history
                } label: {
                    Label(String(localized: "View earnings history"), systemImage: "chart.bar.xaxis")
                }
            }

            Section {
                ColorPicker(
                    LiveEarningsL10n.notchNumberColor,
                    selection: amountColorBinding,
                    supportsOpacity: false
                )
            } header: {
                Text(LiveEarningsL10n.appearance)
            }

            Section {
                Toggle(LiveEarningsL10n.privacyMode, isOn: $draft.privacyModeEnabled)
            } footer: {
                Text(LiveEarningsL10n.privacyDescription)
            }

            if !validationIssues.isEmpty {
                Section {
                    Label(validationIssues.map(LiveEarningsL10n.validation).joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

        }
        .navigationTitle(LiveEarningsL10n.liveEarnings)
        .onAppear {
            guard !didLoad else { return }
            draft = controller.config
            didLoad = true
        }
        .onChange(of: draft) { _, newValue in
            guard didLoad else { return }

            var updated = newValue
            updated.setupCompleted = true
            guard !updated.isEnabled || LiveEarningsEngine().validate(updated).isEmpty else { return }
            controller.save(updated)
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .history:
                LiveEarningsHistoryView()
            case .workCalendar:
                WorkCalendarView()
            }
        }
    }

    private var validationIssues: [LiveEarningsValidationIssue] {
        LiveEarningsEngine().validate(draft)
    }

    private var amountColorBinding: Binding<Color> {
        Binding(
            get: { LiveEarningsAmountColor.color(from: draft.closedAmountColorHex) },
            set: { draft.closedAmountColorHex = LiveEarningsAmountColor.hex(from: $0) }
        )
    }
}

struct LiveEarningsOnboardingView: View {
    @State private var draft = LiveEarningsConfig()
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.green)
            Text(LiveEarningsL10n.setUpTitle)
                .font(.title2.bold())
            Text(LiveEarningsL10n.setUpDescription)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            ScrollView {
                LiveEarningsConfigurationEditor(config: $draft)
                    .padding(.horizontal, 4)
            }

            HStack {
                Button(LiveEarningsL10n.skip) {
                    LiveEarningsController.shared.skipSetup()
                    onSkip()
                }
                Spacer()
                Button(LiveEarningsL10n.continueAction) {
                    draft.setupCompleted = true
                    draft.isEnabled = true
                    LiveEarningsController.shared.save(draft)
                    onContinue()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!LiveEarningsEngine().validate(draft).isEmpty)
            }
        }
        .padding(28)
    }
}

private struct LiveEarningsConfigurationEditor: View {
    @Binding var config: LiveEarningsConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LiveEarningsSalaryFields(config: $config)
            LiveEarningsWorkScheduleFields(config: $config)
        }
    }
}

private struct LiveEarningsSalaryFields: View {
    @Binding var config: LiveEarningsConfig

    var body: some View {
        Group {
            Picker(LiveEarningsL10n.salaryType, selection: $config.salaryMode) {
                Text(LiveEarningsL10n.monthly).tag(LiveEarningsSalaryMode.monthly)
                Text(LiveEarningsL10n.daily).tag(LiveEarningsSalaryMode.daily)
                Text(LiveEarningsL10n.hourly).tag(LiveEarningsSalaryMode.hourly)
            }
            .pickerStyle(.segmented)

            HStack {
                Text(LiveEarningsL10n.amount)
                Spacer()
                TextField("0.00", value: activeAmount, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 130)
                Picker("", selection: $config.currencyCode) {
                    ForEach(currencyCodes, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 92)
            }
        }
    }

    private var activeAmount: Binding<Double> {
        switch config.salaryMode {
        case .monthly: $config.monthlySalary
        case .daily: $config.dailySalary
        case .hourly: $config.hourlyRate
        }
    }

    private var currencyCodes: [String] {
        let preferred = config.currencyCode
        return [preferred] + Locale.commonISOCurrencyCodes.filter { $0 != preferred }.sorted()
    }
}

private struct LiveEarningsWorkScheduleFields: View {
    @Binding var config: LiveEarningsConfig

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(LiveEarningsL10n.workdays)
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    ForEach(orderedWeekdays) { weekday in
                        Button(LiveEarningsL10n.shortWeekday(weekday)) {
                            if config.workdays.contains(weekday) {
                                config.workdays.remove(weekday)
                            } else {
                                config.workdays.insert(weekday)
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(config.workdays.contains(weekday) ? .accentColor : .secondary)
                    }
                }
            }

            HStack {
                DatePicker(LiveEarningsL10n.start, selection: timeBinding(\.workStart), displayedComponents: .hourAndMinute)
                DatePicker(LiveEarningsL10n.end, selection: timeBinding(\.workEnd), displayedComponents: .hourAndMinute)
            }

            Toggle(LiveEarningsL10n.lunchBreak, isOn: $config.lunchBreakEnabled)
            if config.lunchBreakEnabled {
                HStack {
                    DatePicker(LiveEarningsL10n.start, selection: timeBinding(\.lunchStart), displayedComponents: .hourAndMinute)
                    DatePicker(LiveEarningsL10n.end, selection: timeBinding(\.lunchEnd), displayedComponents: .hourAndMinute)
                }
            }
        }
    }

    private var orderedWeekdays: [LiveEarningsWeekday] {
        let all = LiveEarningsWeekday.allCases
        let first = max(1, min(Calendar.current.firstWeekday, all.count)) - 1
        return Array(all[first...] + all[..<first])
    }

    private func timeBinding(_ keyPath: WritableKeyPath<LiveEarningsConfig, LiveEarningsLocalTime>) -> Binding<Date> {
        Binding(
            get: {
                let value = config[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: value.hour, minute: value.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                config[keyPath: keyPath] = .init(hour: components.hour ?? 0, minute: components.minute ?? 0)
            }
        )
    }
}

enum LiveEarningsL10n {
    static var liveEarnings: String { String(localized: "Live Earnings") }
    static var earnedToday: String { String(localized: "Earned today") }
    static var hiddenInPrivacyMode: String { String(localized: "Hidden in privacy mode") }
    static var enable: String { String(localized: "Enable Live Earnings") }
    static var privacyMode: String { String(localized: "Privacy mode") }
    static var privacyDescription: String { String(localized: "Hide salary amounts in the notch and Home.") }
    static var save: String { String(localized: "Save") }
    static var setUpTitle: String { String(localized: "Set up Live Earnings") }
    static var setUpDescription: String { String(localized: "Enter your pay and work schedule to see today's earnings in the notch.") }
    static var skip: String { String(localized: "Not now") }
    static var continueAction: String { String(localized: "Enable & Continue") }
    static var salaryType: String { String(localized: "Pay type") }
    static var monthly: String { String(localized: "Monthly") }
    static var daily: String { String(localized: "Daily") }
    static var hourly: String { String(localized: "Hourly") }
    static var amount: String { String(localized: "Amount") }
    static var appearance: String { String(localized: "Appearance") }
    static var notchNumberColor: String { String(localized: "Notch number color") }
    static var workSchedule: String { String(localized: "Work schedule") }
    static var workdays: String { String(localized: "Workdays") }
    static var start: String { String(localized: "Start") }
    static var end: String { String(localized: "End") }
    static var lunchBreak: String { String(localized: "Pause during lunch") }

    static func shortWeekday(_ value: LiveEarningsWeekday) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        return formatter.veryShortWeekdaySymbols[value.rawValue - 1]
    }

    static func status(_ value: LiveEarningsStatus) -> String {
        switch value {
        case .beforeWork: return String(localized: "Before work")
        case .working: return String(localized: "Earning")
        case .lunchBreak: return String(localized: "Lunch pause")
        case .afterWork: return String(localized: "Finished")
        case .restDay: return String(localized: "Rest day")
        case .publicHoliday: return String(localized: "Public holiday")
        case .leaveDay: return String(localized: "Leave day")
        case .notConfigured: return String(localized: "Not configured")
        case .invalidConfiguration: return String(localized: "Invalid settings")
        }
    }

    static func validation(_ issue: LiveEarningsValidationIssue) -> String {
        switch issue {
        case .salaryMustBePositive: return String(localized: "Pay must be greater than zero")
        case .selectAtLeastOneWorkday: return String(localized: "Select at least one workday")
        case .workTimeOutOfRange: return String(localized: "Work time is invalid")
        case .workEndMustBeAfterStart: return String(localized: "End time must be later than start time")
        case .lunchTimeOutOfRange: return String(localized: "Lunch time is invalid")
        case .lunchMustBeInsideWorkday: return String(localized: "Lunch must be inside work hours")
        }
    }
}
