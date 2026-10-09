import AppIntents
import SwiftUI
import WidgetKit

struct GreyscaleValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        let actual = try await ControlClient.shared.read()
        ControlDiagnostics.event("Tile sampled confirmed greyscale \(actual ? "on" : "off")")
        return actual
    }
}

struct GreyscaleControl: ControlWidget {
    static let kind = AppConfiguration.controlKind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: GreyscaleValueProvider()) { isOn in
            ControlWidgetToggle(
                "Greyscale",
                isOn: isOn,
                action: SetGreyscaleFromControlIntent()
            ) { isOn in
                Label(
                    isOn ? "Greyscale On" : "Greyscale Off",
                    systemImage: isOn ? "circle.lefthalf.filled" : "circle"
                )
            }
        }
        .displayName("Greyscale")
        .description("Turn the greyscale display filter on or off.")
    }
}

@main
struct GreyscaleControlBundle: WidgetBundle {
    var body: some Widget {
        GreyscaleControl()
    }
}
