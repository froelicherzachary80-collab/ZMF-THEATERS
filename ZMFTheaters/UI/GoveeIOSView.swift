import SwiftUI

/// Native iPhone-only Govee setup: explicit discovery, visual test, and
/// opt-in automation. No Windows pairing or internet account required.
struct GoveeIOSView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var previewColor = Color(red: 0.45, green: 0.78, blue: 1.0)
    @State private var testColorWasSent = false

    private var lighting: GoveeIOSController { model.goveeIOS }
    private func colorBytes(_ color: Color) -> CinemaRGB {
        let c = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &alpha)
        return CinemaRGB(UInt8(max(0, min(255, Int(r * 255)))),
                         UInt8(max(0, min(255, Int(g * 255)))),
                         UInt8(max(0, min(255, Int(b * 255)))))
    }

    var body: some View {
        Form {
            Section("Bluetooth · no Windows PC needed") {
                Label(lighting.bluetoothStatus,
                      systemImage: lighting.connected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(lighting.connected ? .green : .primary)
                Text("The Govee strip needs power and a supported local Bluetooth protocol. Connect directly from this iPhone. The Tapo plug and Windows app are not required for lighting.")
                    .font(.caption)
                Button("Scan nearby Govee devices") { lighting.scan() }
                ForEach(lighting.devices) { device in
                    Button {
                        settingsStore.settings.iosGoveeDeviceID = device.id.uuidString
                        settingsStore.settings.iosGoveeVerified = false
                        testColorWasSent = false
                        lighting.connect(to: device.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).foregroundStyle(.primary)
                                Text("Signal \(device.signal) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settingsStore.settings.iosGoveeDeviceID == device.id.uuidString {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                }
            }

            Section("Verify the strip's color protocol") {
                Picker("Model command", selection: $settingsStore.settings.iosGoveeVariant) {
                    ForEach(GoveeColorVariant.allCases) { variant in
                        Text(variant.label).tag(variant)
                    }
                }
                .onChange(of: settingsStore.settings.iosGoveeVariant) { _, _ in
                    settingsStore.settings.iosGoveeVerified = false
                    testColorWasSent = false
                }
                ColorPicker("Color test · any 24-bit RGB", selection: $previewColor)
                Button("Send chosen test color") {
                    lighting.sendTest(colorBytes(previewColor))
                    testColorWasSent = lighting.connected
                }
                .disabled(!lighting.connected)
                Button("Yes, the physical strip changed correctly") {
                    settingsStore.settings.iosGoveeVerified = true
                }
                .disabled(!lighting.connected || !testColorWasSent)
                Text(settingsStore.settings.iosGoveeVerified ?
                     "Color protocol visually verified by you." :
                     "Not verified. If the strip did not change, try A, B or C. Automatic output is disabled until verified.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatic lighting") {
                Toggle("Auto-match movie ambience", isOn: $settingsStore.settings.iosGoveeAuto)
                    .disabled(!settingsStore.settings.iosGoveeVerified)
                VStack(alignment: .leading) {
                    Text("Brightness \(Int(settingsStore.settings.iosGoveeBrightness * 100))%")
                    Slider(value: $settingsStore.settings.iosGoveeBrightness, in: 0.15...1)
                }
                Label("Last command: \(lighting.currentColor.hex)", systemImage: "paintpalette.fill")
                Text(lighting.moodSource).font(.caption).foregroundStyle(.secondary)
                Text("Native movie frames: iPhone samples actual decoded pixels, up to ~3 changes/sec. Bright cool-white frames produce icy blue-white lighting. YouTube: protected pixels cannot be analysed, so it uses a clearly labelled smooth rhythmic palette. No strobe commands. The strip must be powered and within Bluetooth range; behavior varies by model.")
                    .font(.caption)
            }
            Section("Safety") {
                Button("Disable automation") { settingsStore.settings.iosGoveeAuto = false }
                Button("Disconnect lights") {
                    settingsStore.settings.iosGoveeAuto = false
                    lighting.disconnect()
                }
                Text("Disconnecting does not guarantee the lights will switch off; use the Govee app or the light's own switch. Direct iOS automation operates in the foreground and can stop when iOS suspends the app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("iPhone Govee Lighting")
        .onAppear { lighting.beginBluetooth() }
    }
}
