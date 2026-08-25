//
//  ContentView.swift
//  UWBTestApp
//
//  Every control routes through ViewModel, which forwards to the coordinator the same
//  way Unity's calls reach the plugin bridge — configuration is enqueued on the UWB
//  queue, never written across threads into the running pipeline.
//
import SwiftUI

struct ContentView: View {
    @Environment(ViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            List {
                positionSection
                mapSection
                pipelineSection
                sensorsSection
                filterSection
                heightSection
                tuningSection
                diagnosticsSection
            }
            .navigationTitle("UWB Monitor")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Position

    private var positionSection: some View {
        Section("Posicion calculada") {
            PositionCardView(
                filtered: viewModel.state.filteredPos,
                raw: viewModel.state.rawPos,
                residual: viewModel.state.residual,
                activeAnchors: viewModel.state.activeAnchorCount,
                feedingSensors: viewModel.state.feedingSensorCount,
                fixTimestamp: viewModel.state.fixTimestamp
            )
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        Section("Mapa de anchors") {
            Picker(
                "Mapa",
                selection: Binding(
                    get: { viewModel.selectedMap },
                    set: { viewModel.changeMap($0) }
                )
            ) {
                ForEach(viewModel.availableMaps, id: \.self) { map in
                    Text(map).tag(map)
                }
            }
            .pickerStyle(.menu)

            if let mapError = viewModel.mapError {
                Label(mapError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Pipeline lifecycle

    private var pipelineSection: some View {
        Section {
            Toggle(
                "Pipeline activo",
                isOn: Binding(
                    get: { viewModel.isRunning },
                    set: { viewModel.setRunning($0) }
                )
            )

            Button("Reiniciar pipeline") {
                viewModel.restart()
            }
            .font(.callout)
            .disabled(!viewModel.isRunning)
        } header: {
            Text("Pipeline")
        } footer: {
            Text("Ciclos de stop/start repetidos eran el escenario que acumulaba pipelines y filtraba coordinadores. Reiniciar sobre uno activo debe dejar exactamente uno corriendo (los sensores se reconectan, no se duplican).")
                .font(.caption)
        }
    }

    // MARK: - Sensors

    private var sensorsSection: some View {
        Section {
            if viewModel.state.mapSensors.isEmpty {
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text("Cargando sensores...")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(viewModel.state.mapSensors, id: \.self) { sensorId in
                    SensorRowView(
                        sensorId: sensorId,
                        rssi: viewModel.state.discoveredDevices[sensorId],
                        distance: viewModel.state.distances[sensorId],
                        isConnected: viewModel.state.connectedDevices.contains(sensorId),
                        isOutOfRange: viewModel.state.outOfRangeDevices.contains(sensorId),
                        isStale: viewModel.state.staleDevices.contains(sensorId),
                        gatedCount: viewModel.state.gatedCounts[sensorId] ?? 0
                    )
                }
            }
        } header: {
            HStack {
                Text("Sensores")
                Spacer()
                let feeding = viewModel.state.feedingSensorCount
                let connected = viewModel.state.connectedDevices.count
                Text("\(feeding) alimentando · \(connected) conectados")
                    .font(.caption)
                    .foregroundStyle(feeding >= 3 ? .green : .secondary)
            }
        } footer: {
            Text("Máximo 6 conexiones simultáneas: al llegar al límite se libera el ancla más lejana para dejar entrar a una más cercana.")
                .font(.caption)
        }
    }

    // MARK: - Distance filter

    private var filterSection: some View {
        Section {
            Toggle(
                "Filtrar por distancia",
                isOn: Binding(
                    get: { viewModel.state.distanceFilterEnabled },
                    set: { viewModel.setDistanceFilter(enabled: $0, maxDistance: viewModel.state.maxConnectionDistance) }
                )
            )

            if viewModel.state.distanceFilterEnabled {
                sliderRow(
                    label: "Distancia máxima",
                    value: viewModel.state.maxConnectionDistance,
                    format: "%.1f m",
                    range: 0.5...20.0,
                    step: 0.5
                ) { newValue in
                    viewModel.setDistanceFilter(enabled: true, maxDistance: newValue)
                }
            }
        } header: {
            Text("Filtro de distancia")
        } footer: {
            if viewModel.state.distanceFilterEnabled {
                Text("Sensores a más de \(String(format: "%.1f", viewModel.state.maxConnectionDistance))m se excluyen del cálculo (naranja). Se re-incluyen al bajar del 85% del umbral.")
                    .font(.caption)
            }
        }
    }

    // MARK: - Height projection

    private var heightSection: some View {
        Section {
            Toggle(
                "Proyectar al plano del piso",
                isOn: Binding(
                    get: { viewModel.state.userHeightEnabled },
                    set: { viewModel.setUserHeight(enabled: $0, height: viewModel.state.userHeight) }
                )
            )

            if viewModel.state.userHeightEnabled {
                sliderRow(
                    label: "Altura del teléfono",
                    value: viewModel.state.userHeight,
                    format: "%.2f m",
                    range: 0.5...2.0,
                    step: 0.05
                ) { newValue in
                    viewModel.setUserHeight(enabled: true, height: newValue)
                }
            }
        } header: {
            Text("Proyección de altura")
        } footer: {
            Text("Convierte la distancia inclinada en horizontal: d_h = √(d² − (z_ancla − altura)²). Actívalo solo si el mapa registra la z real de las anclas (p. ej. montadas en el techo).")
                .font(.caption)
        }
    }

    // MARK: - Kalman tuning

    private var tuningSection: some View {
        Section {
            sliderRow(
                label: "Ruido de medición (R)",
                value: viewModel.state.measurementStd,
                format: "%.2f m",
                range: 0.02...1.0,
                step: 0.01
            ) { newValue in
                viewModel.setKalmanTuning(measurementStd: newValue, processAccelStd: viewModel.state.processAccelStd)
            }

            sliderRow(
                label: "Aceleración del modelo (Q)",
                value: viewModel.state.processAccelStd,
                format: "%.1f m/s²",
                range: 0.1...3.0,
                step: 0.1
            ) { newValue in
                viewModel.setKalmanTuning(measurementStd: viewModel.state.measurementStd, processAccelStd: newValue)
            }

            Button("Restaurar valores del plugin (0.10 / 0.8)") {
                viewModel.resetTuning()
            }
            .font(.callout)
        } header: {
            Text("Ajuste del filtro de Kalman")
        } footer: {
            Text("Subir R suaviza pero añade retraso; subir Q sigue mejor el movimiento rápido pero tiembla más. Camina una ruta conocida y compara las columnas Filtrado y Crudo: Δ filtro es cuánto está corrigiendo.")
                .font(.caption)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            counterRow(label: "Fixes calculados", value: "\(viewModel.state.fixCount)")
            counterRow(label: "Descartados por colinealidad", value: "\(viewModel.state.collinearSkips)")
            counterRow(label: "Distancias inválidas (≤ 0)", value: "\(viewModel.state.invalidDistanceCount)")
            counterRow(label: "Outliers rechazados", value: "\(viewModel.state.gatedCounts.values.reduce(0, +))")

            Toggle(
                "Logs detallados",
                isOn: Binding(
                    get: { viewModel.state.verboseLogging },
                    set: { viewModel.setVerboseLogging($0) }
                )
            )
        } header: {
            Text("Diagnóstico")
        } footer: {
            Text("Los logs detallados imprimen en cada medición (decenas por segundo) y pueden causar stutter: úsalos solo mientras depuras.")
                .font(.caption)
        }
    }

    // MARK: - Reusable rows

    private func sliderRow(
        label: String,
        value: Double,
        format: String,
        range: ClosedRange<Double>,
        step: Double,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range,
                step: step
            )
        }
    }

    private func counterRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
