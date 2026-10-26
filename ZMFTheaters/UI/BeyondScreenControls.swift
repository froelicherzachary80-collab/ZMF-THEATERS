import SwiftUI

/// Owner controls for the original "movie comes to you" cinema format.
/// Automatic world selection uses Apple Vision only on accessible, decoded
/// movie frames; manual scene selection is always available.
struct BeyondScreenControls: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TheaterSession
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var expanded = false

    var body: some View {
        if session.ticket?.screeningFormat.usesBeyondScreen == true, session.phase == .feature {
            let director = model.beyondScreen
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: director.scene.symbol)
                        .foregroundStyle(.cyan)
                    Text("BEYONDSCREEN 4DX")
                        .font(.caption2.weight(.heavy))
                    Text(director.genre.rawValue.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                    Text("• \(director.scene.label)")
                        .font(.caption2)
                        .foregroundStyle(.cyan)
                    Spacer(minLength: 6)
                    Button(expanded ? "MINIMIZE" : "CUSTOMIZE") {
                        withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                    }.font(.caption2.bold())
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Scene", selection: Binding(
                            get: { director.sceneOverride?.rawValue ?? "auto" },
                            set: { newValue in
                                let scene = BeyondScene(rawValue: newValue)
                                director.select(scene)
                                if let id = session.item?.id {
                                    if let scene {
                                        settingsStore.settings.beyondScreenOverrides[id] = scene
                                    } else {
                                        settingsStore.settings.beyondScreenOverrides.removeValue(forKey: id)
                                    }
                                }
                            }
                        )) {
                            Text("AUTO / VISION").tag("auto")
                            ForEach(BeyondScene.allCases) { scene in
                                Text(scene.label).tag(scene.rawValue)
                            }
                        }.pickerStyle(.menu)
                        Text(director.evidence)
                            .font(.caption2).foregroundStyle(.white.opacity(0.65))
                        Toggle("On-device scene recognition", isOn: $settingsStore.settings.beyondScreenVision)
                        Toggle("Original pop-out figures", isOn: $settingsStore.settings.beyondScreenCharacters)
                        Toggle("Genre-based seat motion", isOn: $settingsStore.settings.beyondScreenMotion)
                        VStack(alignment: .leading) {
                            Text("World intensity \(Int(settingsStore.settings.beyondScreenStrength * 100))%")
                                .font(.caption2)
                            Slider(value: $settingsStore.settings.beyondScreenStrength, in: 0...1)
                        }
                        Button("Disable all BeyondScreen motion and environment") {
                            settingsStore.settings.beyondScreenStrength = 0
                            settingsStore.settings.beyondScreenMotion = false
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        Text("Accessible video frames are classified privately on this iPhone. Cinematic worlds and figures are procedural interpretations, not exact AI recreations of actors or locations. YouTube cannot be frame-analyzed.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .toggleStyle(.switch)
                    .font(.caption)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.black.opacity(0.79), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: 760)
        }
    }
}
