/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import SwiftUI

private enum EarningsHistoryPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    var id: String { rawValue }
}

struct LiveEarningsHistoryView: View {
    @ObservedObject private var controller = LiveEarningsController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var period: EarningsHistoryPeriod = .week
    @State private var anchor = Date()
    @State private var confirmsClear = false

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(String(localized: "Earnings History")).font(.title2.bold())
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
            }

            HStack {
                Picker("", selection: $period) {
                    Text(String(localized: "Day")).tag(EarningsHistoryPeriod.day)
                    Text(String(localized: "Week")).tag(EarningsHistoryPeriod.week)
                    Text(String(localized: "Month")).tag(EarningsHistoryPeriod.month)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                DatePicker("", selection: $anchor, displayedComponents: .date)
                Spacer()
                Button(String(localized: "Clear History"), role: .destructive) { confirmsClear = true }
            }

            HStack(spacing: 12) {
                historyMetric(title: String(localized: "Total earnings"), value: formattedTotal)
                historyMetric(title: String(localized: "Workdays"), value: "\(filteredRecords.filter { $0.status == .completedWorkday }.count)")
                historyMetric(title: String(localized: "Paid hours"), value: String(format: "%.1f", paidHours))
            }

            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    String(localized: "No earnings history"),
                    systemImage: "chart.bar.xaxis",
                    description: Text(String(localized: "History starts when Phase 2 records a completed workday."))
                )
                .frame(maxHeight: .infinity)
            } else {
                List(filteredRecords) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.date.encoded).font(.headline.monospacedDigit())
                            Text(detail(for: record)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(LiveEarningsFormatting.amount(record.finalAmount, currencyCode: record.currencyCode, includesSymbol: true))
                            .font(.headline.monospacedDigit())
                    }
                    .padding(.vertical, 4)
                }
            }

            if let error = controller.historyError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 560)
        .task { await controller.reloadHistory() }
        .confirmationDialog(String(localized: "Clear all earnings history?"), isPresented: $confirmsClear) {
            Button(String(localized: "Clear History"), role: .destructive) {
                Task { try? await controller.clearHistory() }
            }
        } message: {
            Text(String(localized: "This removes daily records only. Salary settings and work-calendar overrides are kept."))
        }
    }

    private var filteredRecords: [DayEarningsRecord] {
        let range = selectedRange
        return controller.historyRecords.filter { range.contains($0.date) }.sorted { $0.date > $1.date }
    }

    private var selectedRange: ClosedRange<LocalDate> {
        let calendar = Calendar.autoupdatingCurrent
        let start: Date
        let end: Date
        switch period {
        case .day:
            start = calendar.startOfDay(for: anchor)
            end = start
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: anchor)!
            start = interval.start
            end = calendar.date(byAdding: .day, value: 6, to: start)!
        case .month:
            start = calendar.startOfMonth(containing: anchor)
            end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
        }
        return LocalDate(start, calendar: calendar)...LocalDate(end, calendar: calendar)
    }

    private var total: Decimal {
        filteredRecords.reduce(Decimal.zero) { $0 + $1.finalAmount }
    }

    private var formattedTotal: String {
        LiveEarningsFormatting.amount(total, currencyCode: controller.config.currencyCode, includesSymbol: true)
    }

    private var paidHours: Double {
        filteredRecords.reduce(0) { $0 + $1.paidSeconds } / 3600
    }

    private func historyMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func detail(for record: DayEarningsRecord) -> String {
        let status: String
        switch record.status {
        case .completedWorkday: status = String(localized: "Completed workday")
        case .publicHoliday: status = String(localized: "Public holiday")
        case .restDay: status = String(localized: "Rest day")
        case .leaveDay: status = String(localized: "Leave day")
        }
        return "\(status) · \(record.scheduleSource.rawValue) · \(String(format: "%.1f", record.paidSeconds / 3600)) h"
    }
}
