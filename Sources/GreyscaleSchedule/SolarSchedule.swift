import Darwin
import Foundation
import ObjectiveC

enum SolarScheduleError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "macOS isn't providing current sunrise and sunset times. Retry or choose Custom."
    }
}

struct SolarBoundary: Equatable, Codable {
    enum Kind: String, Codable { case sunrise, sunset }
    let date: Date
    let kind: Kind
    var enablesGreyscale: Bool { kind == .sunset }
}

/// Validated absolute dates, not yesterday's times repeated in the local zone.
struct SolarScheduleSnapshot: Equatable {
    let previous: SolarBoundary
    let next: SolarBoundary

    init(properties: [String: Any], on now: Date) throws {
        let keys: [(String, SolarBoundary.Kind)] = [
            ("previousSunrise", .sunrise), ("sunrise", .sunrise), ("nextSunrise", .sunrise),
            ("previousSunset", .sunset), ("sunset", .sunset), ("nextSunset", .sunset),
        ]
        let events = keys.compactMap { key, kind -> SolarBoundary? in
            guard let date = properties[key] as? Date,
                  date.timeIntervalSinceReferenceDate.isFinite else { return nil }
            return SolarBoundary(date: date, kind: kind)
        }.sorted { $0.date < $1.date }
        guard let previous = events.last(where: { $0.date <= now }),
              let next = events.first(where: { $0.date > now }),
              previous.kind != next.kind,
              now.timeIntervalSince(previous.date) <= 36 * 3_600,
              next.date.timeIntervalSince(now) <= 36 * 3_600,
              next.date.timeIntervalSince(previous.date) <= 36 * 3_600,
              !events.contains(where: { event in
                  events.contains { $0.date == event.date && $0.kind != event.kind }
              }) else { throw SolarScheduleError.unavailable }
        self.previous = previous; self.next = next
    }
    func desiredState(on date: Date) -> Bool? {
        guard previous.date <= date, date < next.date else { return nil }
        return previous.enablesGreyscale
    }
}

/// Read-only private compatibility boundary. No app location request, Night
/// Shift enablement, or writes to macOS's solar data are needed.
enum SystemSolarSchedule {
    private static let framework = dlopen(
        "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
        RTLD_LAZY | RTLD_LOCAL
    )
    static func read(on date: Date = Date()) throws -> SolarScheduleSnapshot {
        guard framework != nil,
              let type = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else {
            throw SolarScheduleError.unavailable
        }
        let selector = NSSelectorFromString("copyPropertyForKey:")
        let client = type.init()
        guard client.responds(to: selector),
              let method = class_getInstanceMethod(type, selector),
              method_getNumberOfArguments(method) == 3 else { throw SolarScheduleError.unavailable }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        guard returnType.pointee == 64,
              let result = client.perform(selector, with: "BlueLightSunSchedule")?.takeRetainedValue(),
              let properties = result as? [String: Any] else { throw SolarScheduleError.unavailable }
        return try SolarScheduleSnapshot(properties: properties, on: date)
    }
}

/// Periodic reads only refresh the next deadline. A manual choice is not
/// overwritten until the system reports a different most-recent boundary.
actor SolarScheduleDriver {
    private var handled: SolarBoundary?
    private let didApply: (SolarBoundary) -> Void
    init(handled: SolarBoundary? = nil, didApply: @escaping (SolarBoundary) -> Void = { _ in }) {
        self.handled = handled; self.didApply = didApply
    }
    func apply(_ snapshot: SolarScheduleSnapshot,
               set: (Bool) async throws -> Void) async throws {
        guard snapshot.previous != handled else { return }
        try await set(snapshot.previous.enablesGreyscale)
        handled = snapshot.previous
        didApply(snapshot.previous)
    }
}

enum SolarBoundaryStore {
    private static let key = "solar.lastAppliedBoundary.v1"
    static func load(from defaults: UserDefaults = .standard) -> SolarBoundary? {
        defaults.synchronize()
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SolarBoundary.self, from: data)
    }
    static func save(_ boundary: SolarBoundary, to defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(boundary), forKey: key)
        defaults.synchronize()
    }
}

// The one-shot timer and immutable references are used on their serial queue.
// Driver state is actor-isolated; no overlapping tick is scheduled during a set.
final class SolarScheduleRuntime: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.greyscale-schedule.solar")
    private let timer: DispatchSourceTimer
    private let driver: SolarScheduleDriver
    init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        driver = SolarScheduleDriver(handled: SolarBoundaryStore.load(), didApply: { SolarBoundaryStore.save($0) })
    }
    func start() {
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(wallDeadline: .now())
        timer.resume()
    }
    private func tick() {
        guard SettingsStore.load().mode == .sunsetToSunrise else { exit(0) }
        Task {
            var delay: TimeInterval = 60
            do {
                let now = Date()
                let snapshot = try SystemSolarSchedule.read(on: now)
                try await driver.apply(snapshot) { _ = try await ControlClient.shared.set($0) }
                delay = max(0.5, min(60, snapshot.next.date.timeIntervalSinceNow))
            } catch {
                ControlDiagnostics.record("Solar schedule: \(error.localizedDescription)")
            }
            // Wall-clock deadlines catch up after sleep or a clock change.
            // Re-read within a minute to pick up updated system solar dates.
            let nextDelay = delay
            queue.async { self.timer.schedule(wallDeadline: .now() + nextDelay, leeway: .milliseconds(250)) }
        }
    }
    static func run() -> Never {
        let runtime = SolarScheduleRuntime()
        runtime.start()
        withExtendedLifetime(runtime) { dispatchMain() }
    }
}
