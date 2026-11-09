//
//  EngravingDateSheet.swift
//  Snowglobe
//
//  Picks the date engraved under the name on a globe's brass plaque (opened with the pencil
//  next to View in AR). Photo globes start with the date the photo was taken; demo globes
//  like Times Square start without one.
//

import SwiftUI

struct EngravingDateSheet: View {
    let title: String
    /// The date engraved right now (nil = name only).
    let currentDate: Date?
    /// Called with the new date, or nil to remove it.
    let onSave: (Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(title: String, currentDate: Date?, onSave: @escaping (Date?) -> Void) {
        self.title = title
        self.currentDate = currentDate
        self.onSave = onSave
        _date = State(initialValue: currentDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    plaquePreview
                    DatePicker("Engraved date", selection: $date, in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(Theme.accent)
                    if currentDate != nil {
                        Button("Remove Date", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                        .font(Theme.font(.body, weight: .medium))
                    }
                }
                .padding()
            }
            .navigationTitle("Engraving")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(date)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }

    /// A little brass plaque showing how the engraving will read.
    private var plaquePreview: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.custom("Georgia-Bold", size: 20))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(GlobeEntityFactory.engravingText(for: date))
                .font(.custom("Georgia", size: 16))
                .monospacedDigit()
        }
        .foregroundStyle(Color(red: 0.18, green: 0.11, blue: 0.05))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 280)
        .background(
            LinearGradient(colors: [Color(red: 0.86, green: 0.71, blue: 0.40), Color(red: 0.66, green: 0.50, blue: 0.24)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plaque preview: \(title), \(date.formatted(date: .long, time: .omitted))")
    }
}

#Preview {
    EngravingDateSheet(title: "Times Square", currentDate: nil) { _ in }
        .preferredColorScheme(.dark)
}
