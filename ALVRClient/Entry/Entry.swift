/*
Abstract:
The Entry content for a volume: connection status, a few switches and the Enter button, in one column so nothing sits outside the window.
*/

import SwiftUI
import UIKit

struct Entry: View {
    @ObservedObject var eventHandler = EventHandler.shared
    @EnvironmentObject var gStore: GlobalSettingsStore
    @ObservedObject var floorReadout = FloorReadout.shared
    /// True while the reading is coming from the headset right now; dimmed when it is the last session's.
    @State private var floorReadingIsLive = false
    @Environment(\.scenePhase) private var scenePhase
    let saveAction: ()->Void

    private var heightOffsetCm: Binding<Double> {
        Binding(
            get: { Double(gStore.settings.heightOffsetCm) },
            set: { gStore.settings.heightOffsetCm = Int($0.rounded()) }
        )
    }

    /// "HMD 1.62 m + offset +5 cm = 1.67 m"
    private var heightLine: String {
        let offset = gStore.settings.heightOffsetCm
        guard let head = floorReadout.headY else {
            return String(format: "HMD – + offset %+d cm = –", offset)
        }
        return String(format: "HMD %.2f m + offset %+d cm = %.2f m", head, offset, head + Float(offset) / 100.0)
    }

    var body: some View {
        VStack(spacing: 20) {
        VStack {
            VStack {
                Image(.alvrCombinedLogoHqLight)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel("AirFrameXR logo")
                .frame(maxWidth: .infinity, maxHeight: 150)
                .padding(.top)

                if eventHandler.alvrVersion != "" {
                    Text(eventHandler.alvrVersion)
                        .font(.system(size: 20, weight: .bold))
                }
                else {
                    Text("Loading settings...")
                        .font(.system(size: 20, weight: .bold))
                }

                VStack {
                    Text(eventHandler.connectionFlavorText)
                        .font(.system(size: 15))
                }
                .frame( maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .top)
            }
            .frame(minHeight: 200)

            VStack {
                Text(heightLine)
                    .monospacedDigit()
                    .foregroundStyle(floorReadingIsLive ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                        guard !EventHandler.shared.renderStarted else { return }
                        if let y = WorldTracker.shared.currentHeadHeight() {
                            floorReadingIsLive = true
                            floorReadout.record(headY: y)
                        } else {
                            floorReadingIsLive = false
                        }
                    }
                Slider(value: heightOffsetCm, in: -50...50, step: 1) {
                    Text("Floor height offset")
                }
                .onChange(of: gStore.settings.heightOffsetCm) {
                    saveAction()
                }
            }
            .padding(.horizontal)
            .padding(.top)

            VStack(spacing: 14) {
                Toggle(isOn: Binding(
                    get: { !gStore.settings.fovCustom },
                    set: { isDefault in
                        if isDefault {
                            gStore.settings.fovScaleH = 1.0
                            gStore.settings.fovScaleV = 1.0
                        }
                        gStore.settings.fovCustom = !isDefault
                        saveAction()
                    }
                )) {
                    Text("Default FoV")
                }
                .toggleStyle(.switch)
                if gStore.settings.fovCustom {
                    FovSliderRow(title: "Horizontal FoV", value: $gStore.settings.fovScaleH, saveAction: saveAction)
                    FovSliderRow(title: "Vertical FoV", value: $gStore.settings.fovScaleV, saveAction: saveAction)
                }
            }
            .padding(.horizontal)
            .padding(.top)

            VStack {
                Toggle(isOn: Binding(
                    get: { gStore.settings.chaperoneDistanceCm > 0 },
                    set: { gStore.settings.chaperoneDistanceCm = $0 ? 30 : 0; saveAction() }
                )) {
                    Text("Proximity chaperone")
                }
                .toggleStyle(.switch)
                Picker("Translation correction", selection: $gStore.settings.translationPlaneCm) {
                    Text("Off").tag(0)
                    Text("1.5 m").tag(150)
                    Text("3 m").tag(300)
                    Text("6 m").tag(600)
                    Text("12 m").tag(1200)
                }
                .onChange(of: gStore.settings.translationPlaneCm) {
                    saveAction()
                }
                Toggle(isOn: $gStore.settings.autoConnect) {
                    Text("Auto-connect")
                }
                .toggleStyle(.switch)
                .onChange(of: gStore.settings.autoConnect) {
                    saveAction()
                }
            }
            .padding(.horizontal)
            .padding(.top)

            VStack {
                if eventHandler.hostname != "" && eventHandler.IP != "" {
                    let columns = [
                        GridItem(.fixed(150), alignment: .trailing),
                        GridItem(.fixed(150), alignment: .leading)
                    ]

                    LazyVGrid(columns: columns) {
                        Text("hostname:")
                        Text(eventHandler.hostname)
                        Text("IP:")
                        Text(eventHandler.IP)
                        Text("Streamer Version:")
                        if eventHandler.hostAlvrVersion != "" {
                            Text(eventHandler.hostAlvrVersion)
                        }
                        else {
                            Text("Disconnected")
                        }
                    }
                    .frame(width: 300, alignment: .center)
                    .padding(.vertical)
                }
            }
        }
        .frame(minWidth: 650, maxWidth: 650)
        .padding(.bottom)
        .glassBackgroundEffect()
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background, .inactive:
                saveAction()
            case .active:
                break
            @unknown default:
                break
            }
        }

        EntryControls(saveAction: saveAction)
            .padding(.bottom, 24)
        }
    }
}

/// A FoV slider (0.6 to 1.4) with the middle, 1.0, marked on the track (the value is printed next to the title).
/// Values are snapped to the 0.05 grid so 1.0 is exactly 1.0 (not 0.99999994), which the declared field of view relies on
/// to equal the stock frustum.
struct FovSliderRow: View {
    let title: String
    @Binding var value: Float
    let saveAction: () -> Void

    private var snapped: Binding<Float> {
        Binding(
            get: { value },
            set: { value = (min(fovScaleRange.upperBound, max(fovScaleRange.lowerBound, $0)) * 20).rounded() / 20 }
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value))
                    .monospacedDigit()
            }
            ZStack {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 3, height: 20)
                Slider(value: snapped, in: fovScaleRange, step: 0.05) {
                    Text(title)
                }
            }
        }
        .onChange(of: value) {
            saveAction()
        }
    }
}
