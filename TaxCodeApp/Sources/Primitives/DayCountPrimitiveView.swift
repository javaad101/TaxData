import SwiftUI

struct DayCountPrimitiveView: View {
    @Binding var state: DayCountState

    private var calendar: Calendar { Calendar.current }

    private var rawDaySpan: Int {
        let s = calendar.startOfDay(for: state.startDate)
        let e = calendar.startOfDay(for: state.endDate)
        let base = calendar.dateComponents([.day], from: s, to: e).day ?? 0
        let sign = base >= 0 ? 1 : -1
        var adjustment = 0
        if state.includeStartDate && state.includeEndDate {
            adjustment = 1
        } else if !state.includeStartDate && !state.includeEndDate {
            adjustment = -1
        }
        return base == 0
            ? (state.includeStartDate && state.includeEndDate ? 1 : 0)
            : base + (sign * adjustment)
    }

    private var businessDays: Int {
        let s = calendar.startOfDay(for: min(state.startDate, state.endDate))
        let e = calendar.startOfDay(for: max(state.startDate, state.endDate))
        var cursor = state.includeStartDate ? s : (calendar.date(byAdding: .day, value: 1, to: s) ?? s)
        let limit = state.includeEndDate ? e : (calendar.date(byAdding: .day, value: -1, to: e) ?? e)
        guard cursor <= limit else { return 0 }
        var count = 0
        var steps = 0
        while cursor <= limit && steps < 40_000 {
            if !calendar.isDateInWeekend(cursor) {
                count += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            steps += 1
        }
        return count
    }

    private var targetDate: Date {
        calendar.date(byAdding: .day, value: state.offsetDays, to: calendar.startOfDay(for: state.anchorDate)) ?? state.anchorDate
    }

    private var weightedSPT: Double {
        Double(state.currentYearDays)
            + (Double(state.priorYear1Days) / 3.0)
            + (Double(state.priorYear2Days) / 6.0)
    }

    var body: some View {
        Form {
            Section("Day Span") {
                DatePicker("Start", selection: $state.startDate, displayedComponents: .date)
                DatePicker("End", selection: $state.endDate, displayedComponents: .date)
                Toggle("Include Start Date", isOn: $state.includeStartDate)
                Toggle("Include End Date", isOn: $state.includeEndDate)

                LabeledContent("Calendar Days") {
                    Text("\(rawDaySpan)")
                        .font(.headline.monospacedDigit())
                }
                LabeledContent("Business Days") {
                    Text("\(businessDays)")
                        .font(.body.monospacedDigit())
                }
            }

            Section("Deadline / Offset") {
                DatePicker("Anchor Date", selection: $state.anchorDate, displayedComponents: .date)
                HStack {
                    Text("Offset Days")
                    Spacer()
                    TextField("Days", value: $state.offsetDays, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .font(.body.monospacedDigit())
                }
                HStack(spacing: 6) {
                    ForEach([30, 45, 60, 90, 180, 183, 365], id: \.self) { preset in
                        Button("\(preset)d") {
                            state.offsetDays = preset
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                LabeledContent("Result Date") {
                    Text(targetDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
                        .font(.headline)
                }
            }

            Section("§ 7701(b) Substantial Presence") {
                HStack {
                    Text("Current Year Days")
                    Spacer()
                    TextField("0", value: $state.currentYearDays, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .font(.body.monospacedDigit())
                }
                HStack {
                    Text("Prior Year 1 Days (× 1/3)")
                    Spacer()
                    TextField("0", value: $state.priorYear1Days, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .font(.body.monospacedDigit())
                }
                HStack {
                    Text("Prior Year 2 Days (× 1/6)")
                    Spacer()
                    TextField("0", value: $state.priorYear2Days, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .font(.body.monospacedDigit())
                }
                LabeledContent("Weighted Total") {
                    let meets = state.currentYearDays >= 31 && weightedSPT >= 183.0
                    Text("\(weightedSPT, specifier: "%.1f") days\(meets ? " (≥ 183)" : "")")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(meets ? Color.orange : Color.primary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
