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

enum ScheduleMode: String, Codable, CaseIterable {
    case off, custom, sunsetToSunrise
    var title: String {
        switch self {
        case .off: return "Off"
        case .custom: return "Custom"
        case .sunsetToSunrise: return "Sunset to Sunrise"
        }
    }
}

struct ScheduleSettings: Equatable, Codable {
    var mode: ScheduleMode
    var start: TimeOfDay
    var end: TimeOfDay
    var enabled: Bool {
        get { mode != .off }
        set { mode = newValue ? (mode == .off ? .custom : mode) : .off }
    }

    init(mode: ScheduleMode, start: TimeOfDay, end: TimeOfDay) {
        self.mode = mode; self.start = start; self.end = end
    }

    init(enabled: Bool, start: TimeOfDay, end: TimeOfDay) {
        self.init(mode: enabled ? .custom : .off, start: start, end: end)
    }

    private enum CodingKeys: String, CodingKey { case mode, enabled, start, end }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try values.decodeIfPresent(ScheduleMode.self, forKey: .mode) {
            self.mode = mode
        } else {
            mode = try values.decode(Bool.self, forKey: .enabled) ? .custom : .off
        }
        let start = try values.decode(TimeOfDay.self, forKey: .start)
        let end = try values.decode(TimeOfDay.self, forKey: .end)
        self.start = TimeOfDay(hour: start.hour, minute: start.minute)
        self.end = TimeOfDay(hour: end.hour, minute: end.minute)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encode(start, forKey: .start)
        try values.encode(end, forKey: .end)
    }

    static let standard = ScheduleSettings(
        enabled: true,
        start: TimeOfDay(hour: 22, minute: 0),
        end: TimeOfDay(hour: 5, minute: 0)
    )

    func shouldEnable(atMinute minute: Int) -> Bool {
        guard mode == .custom else { return false }
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
    func desiredState(on date: Date = Date(), calendar: Calendar = .current,
                      solar: SolarScheduleSnapshot? = nil) -> Bool? {
        switch mode {
        case .off: return nil
        case .custom: return shouldEnable(on: date, calendar: calendar)
        case .sunsetToSunrise: return solar?.desiredState(on: date)
        }
    }
}

enum SettingsStore {
    private static let recordKey = "schedule.v3"
    private enum Key {
        static let enabled = "scheduleEnabled"
        static let startHour = "startHour"
        static let startMinute = "startMinute"
        static let endHour = "endHour"
        static let endMinute = "endMinute"
    }

    static func load(from defaults: UserDefaults = .standard) -> ScheduleSettings {
        defaults.synchronize()
        for key in [recordKey, "schedule.v2"] {
            if let data = defaults.data(forKey: key),
               let record = try? JSONDecoder().decode(ScheduleSettings.self, from: data) {
                return record
            }
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
                      solar: SolarScheduleSnapshot? = nil,
                      set: (Bool) async throws -> Void) async throws {
        let desired = settings.desiredState(on: date, calendar: calendar, solar: solar)
        if settings.mode == .sunsetToSunrise && desired == nil { throw SolarScheduleError.unavailable }
        guard let desired else { return }
        try await set(desired)
    }

    static func applyCurrentSchedule() async throws {
        let settings = SettingsStore.load()
        if settings.mode == .sunsetToSunrise {
            // A slow display write may cross a boundary. Finish an explicit
            // Save with fresh sun data rather than leaving the previous phase.
            for _ in 0..<3 {
                let now = Date()
                let solar = try SystemSolarSchedule.read(on: now)
                try await apply(settings, on: now, solar: solar) { _ = try await ControlClient.shared.set($0) }
                let confirmed = try SystemSolarSchedule.read()
                if solar.previous == confirmed.previous {
                    SolarBoundaryStore.save(confirmed.previous)
                    return
                }
            }
            throw SolarScheduleError.unavailable
        }
        let now = Date()
        try await apply(settings, on: now) { _ = try await ControlClient.shared.set($0) }
    }

    static func definition(settings: ScheduleSettings, executable: String,
                           fingerprint: String? = nil) -> [String: Any]? {
        guard settings.enabled else { return nil }
        if settings.mode == .sunsetToSunrise {
            var definition: [String: Any] = [
                "Label": AppConfiguration.launchAgentLabel,
                "ProgramArguments": [executable, "--serve-solar-schedule"],
                "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Background",
                "StandardOutPath": AppPaths.log.path, "StandardErrorPath": AppPaths.log.path,
            ]
            if let fingerprint { definition["EnvironmentVariables"] = ["GREYSCALE_SCHEDULE_BINARY_SHA256": fingerprint] }
            return definition
        }
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
        // Do not replace a working schedule with a solar mode we cannot evaluate.
        if settings.mode == .sunsetToSunrise { _ = try SystemSolarSchedule.read(on: Date()) }
        try ControlRequestAgent.install()
        guard let executable = Bundle.main.executableURL?.path else { throw CocoaError(.fileNoSuchFile) }
        let previous = SettingsStore.load()
        SettingsStore.save(settings)
        do {
            let fingerprint = settings.mode == .sunsetToSunrise ? try ControlRequestAgent.fingerprint(executable: executable) : nil
            if let definition = definition(settings: settings, executable: executable, fingerprint: fingerprint) {
                try LaunchAgentManager.install(definition, at: AppPaths.launchAgent, label: AppConfiguration.launchAgentLabel)
            } else { try remove() }
        } catch {
            SettingsStore.save(previous)
            throw error
        }
        do { try await applyCurrentSchedule() }
        catch { throw ScheduleSaveError.displayUpdateFailed(error.localizedDescription) }
    }

    static func remove() throws {
        try LaunchAgentManager.remove(at: AppPaths.launchAgent, label: AppConfiguration.launchAgentLabel)
    }
}

enum ScheduleSaveError: LocalizedError {
    case displayUpdateFailed(String)
    var errorDescription: String? {
        switch self {
        case .displayUpdateFailed(let detail): return "The schedule was saved, but the display update failed. \(detail)"
        }
    }
}
