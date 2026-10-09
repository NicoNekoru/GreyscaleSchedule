import AppIntents

/// macOS Control Centre requires dynamic dispatch to produce a runnable action
/// binding in this build. It starts headlessly, never requests foregrounding,
/// and the app's execution tracker prevents settings-window presentation.
struct SetGreyscaleFromControlIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Set Greyscale"
    static let description = IntentDescription(
        "Turns the macOS greyscale display filter on or off."
    )
    static let supportedModes: IntentModes = [.foreground(.dynamic)]
    static let isDiscoverable = false

    @Parameter(title: "Greyscale is enabled")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let ticket = ControlIntentExecutionState.begin()
        defer { ControlIntentExecutionState.finish(ticket) }
        ControlDiagnostics.event("Control intent requested greyscale \(value ? "on" : "off")")
        try await ControlClient.shared.set(value)
        return .result()
    }
}
