import BusinessBarCore
import EventKit
import SwiftUI

struct CalendarSelectionStep: View {
    let onBack: () -> Void
    let onFinish: () -> Void

    @AppStorage(Constants.Defaults.calendarProvider) private var calendarProvider = CalendarProvider.eventKit.rawValue

    @State private var calendars: [MBCalendar] = []
    @State private var selectedCalendarIDs: Set<String> = []
    @State private var isLoading = true

    private var usesMacCalendar: Bool {
        calendarProvider == CalendarProvider.eventKit.rawValue
    }
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Select Your Calendars")
                .font(.largeTitle)
                .bold()
            
            if !usesMacCalendar {
                Text("Google Calendar is selected. You can finish setup and manage calendars later in Preferences.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxHeight: .infinity)
            } else {
                Text("Choose which calendars to display:")
                    .foregroundColor(.secondary)

                if isLoading {
                    ProgressView("Loading calendars...")
                        .frame(maxHeight: .infinity)
                } else if calendars.isEmpty {
                    Text("No calendars available")
                        .foregroundColor(.secondary)
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            let groupedCalendars = Dictionary(grouping: calendars, by: { $0.source })

                            ForEach(Array(groupedCalendars.keys.sorted()), id: \.self) { source in
                                Text(source + ":")
                                    .font(.headline)
                                    .padding(.top, 8)

                                ForEach(groupedCalendars[source] ?? []) { calendar in
                                    Toggle(isOn: Binding(
                                        get: { selectedCalendarIDs.contains(calendar.id) },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedCalendarIDs.insert(calendar.id)
                                            } else {
                                                selectedCalendarIDs.remove(calendar.id)
                                            }
                                        }
                                    )) {
                                        HStack {
                                            Circle()
                                                .fill(Color(hex: calendar.color) ?? .gray)
                                                .frame(width: 12, height: 12)
                                            Text(calendar.title)
                                        }
                                    }
                                    .padding(.leading, 16)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            
            HStack {
                Button("Back") {
                    onBack()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Finish Setup") {
                    if usesMacCalendar {
                        saveSelection()
                    }
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .disabled(usesMacCalendar && selectedCalendarIDs.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding(40)
        .task {
            if usesMacCalendar {
                await loadCalendars()
            } else {
                isLoading = false
            }
        }
    }
    
    private func loadCalendars() async {
        let adapter = EKEventStoreAdapter()
        do {
            calendars = try await adapter.fetchCalendars()
            selectedCalendarIDs = Set(calendars.map { $0.id })
            isLoading = false
        } catch {
            print("Failed to load calendars: \(error)")
            isLoading = false
        }
    }
    
    private func saveSelection() {
        let calendarIDs = Array(selectedCalendarIDs)
        if let data = try? JSONEncoder().encode(calendarIDs) {
            UserDefaults.standard.set(data, forKey: Constants.Defaults.selectedCalendars)
        }
    }
}
