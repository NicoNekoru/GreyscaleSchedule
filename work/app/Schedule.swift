import Darwin
import Foundation

struct TimeOfDay: Equatable, Codable {
    let hour: Int
    let minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    var minutesSinceMidnight: Int { hour * 60 + minute }
}

struct ScheduleSettings: Equatable, Codable {
    var enabled: Bool
    var start: TimeOfDay
    var end: TimeOfDay

    static let standard = ScheduleSettings(
        enabled: true,
        start: TimeOfDay(hour: 22, minute: 0),
        end: TimeOfDay(hour: 5, minute: 0)
    )

    func shouldEnable(atMinute minute: Int) -> Bool {
        guard enabled else { return false }
        let now = min(max(minute, 0), 1_439)
        let startMinute = start.minutesSinceMidnight
        let endMinute = end.minutesSinceMidnight

        if startMinute == endMinute { return true }
        if startMinute < endMinute {
            return now >= startMinute && now < endMinute
        }
        return now >= startMinute || now < endMinute
    }

    func shouldEnable(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return shouldEnable(
            atMinute: (components.hour ?? 0) * 60 + (components.minute ?? 0)
        )
    }

    /// Disabled automation does nothing, rather than forcing a manual choice off.
    func desiredState(on date: Date = Date(), calendar: Calendar = .current) -> Bool? {
        enabled ? shouldEnable(on: date, calendar: calendar) : nil
    }
}

enum SettingsStore {
    private static let recordKey = "schedule.v2"
    private enum Key {
        static let enabled = "scheduleEnabled"
        static let startHour = "startHour"
        static let startMinute = "startMinute"
        static let endHour = "endHour"
        static let endMinute = "endMinute"
    }

    static func load(from defaults: UserDefaults = .standard) -> ScheduleSettings {
        defaults.synchronize()
        if let data = defaults.data(forKey: recordKey),
           let record = try? JSONDecoder().decode(ScheduleSettings.self, from: data) {
            return ScheduleSettings(enabled: record.enabled,
                start: TimeOfDay(hour: record.start.hour, minute: record.start.minute),
                end: TimeOfDay(hour: record.end.hour, minute: record.end.minute))
        }
        let fallback = ScheduleSettings.standard
        defaults.register(defaults: [
            Key.enabled: fallback.enabled,
            Key.startHour: fallback.start.hour,
            Key.startMinute: fallback.start.minute,
            Key.endHour: fallback.end.hour,
            Key.endMinute: fallback.end.minute,
        ])
        return ScheduleSettings(
            enabled: defaults.bool(forKey: Key.enabled),
            start: TimeOfDay(
                hour: defaults.integer(forKey: Key.startHour),
                minute: defaults.integer(forKey: Key.startMinute)
            ),
            end: TimeOfDay(
                hour: defaults.integer(forKey: Key.endHour),
                minute: defaults.integer(forKey: Key.endMinute)
            )
        )
    }

    static func save(_ settings: ScheduleSettings, to defaults: UserDefaults = .standard) {
        // A timer in another process sees one complete settings record.
        defaults.set(try? JSONEncoder().encode(settings), forKey: recordKey)
        defaults.synchronize()
    }
}

enum ScheduleService {
    static func apply(_ settings: ScheduleSettings, on date: Date = Date(),
                      calendar: Calendar = .current,
                      set: (Bool) async throws -> Void) async throws {
        guard let desired = settings.desiredState(on: date, calendar: calendar) else { return }
        try await set(desired)
    }

    static func applyCurrentSchedule() async throws {
        try await apply(SettingsStore.load()) { _ = try await ControlClient.shared.set($0) }
    }

    static func definition(settings: ScheduleSettings, executable: String) -> [String: Any]? {
        guard settings.enabled else { return nil }
        return [
            "Label": AppConfiguration.launchAgentLabel,
            "ProgramArguments": [executable, "--apply-schedule"],
            "RunAtLoad": true,
            "StartCalendarInterval": [
                ["Hour": settings.start.hour, "Minute": settings.start.minute],
                ["Hour": settings.end.hour, "Minute": settings.end.minute],
            ],
            "ProcessType": "Background",
            "StandardOutPath": AppPaths.log.path,
            "StandardErrorPath": AppPaths.log.path,
        ]
    }

    static func install(settings: ScheduleSettings) async throws {
        try ControlRequestAgent.install()
        guard let executable = Bundle.main.executableURL?.path else { throw CocoaError(.fileNoSuchFile) }
        let previous = SettingsStore.load()
        SettingsStore.save(settings)
        do {
            if let definition = definition(settings: settings, executable: executable) {
                try LaunchAgentManager.install(definition, at: AppPaths.launchAgent, label: AppConfiguration.launchAgentLabel)
            } else { try remove() }
        } catch {
            SettingsStore.save(previous)
            throw error
        }
        try await applyCurrentSchedule()
    }

    static func remove() throws {
        try LaunchAgentManager.remove(at: AppPaths.launchAgent, label: AppConfiguration.launchAgentLabel)
    }
}
