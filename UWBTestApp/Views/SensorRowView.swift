//
//  SensorRowView.swift
//  UWBTestApp
//
import SwiftUI

struct SensorRowView: View {
    let sensorId: String
    let rssi: Double?
    let distance: Double?
    let isConnected: Bool
    let isOutOfRange: Bool
    /// Connected but its last measurement is older than the freshness window, so it is
    /// no longer feeding the fix even though the session is alive.
    let isStale: Bool
    /// Measurements rejected by the outlier gate for this sensor since it connected.
    let gatedCount: Int

    private var status: SensorStatus {
        if isConnected && isStale { return .stale }
        if isConnected && isOutOfRange { return .outOfRange }
        if isConnected { return .connected }
        if rssi != nil { return .discovered }
        return .notSeen
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(status.color)
                .frame(width: 10, height: 10)
                .animation(.easeInOut(duration: 0.3), value: status)

            VStack(alignment: .leading, spacing: 2) {
                Text("…\(shortId)")
                    .font(.system(.body, design: .monospaced))
                HStack(spacing: 6) {
                    Text(status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if gatedCount > 0 {
                        Text("\(gatedCount) outliers")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let distance {
                    Text(String(format: "%.2f m", distance))
                        .font(.system(.callout, design: .monospaced))
                        .bold()
                        .foregroundStyle(distanceColor)
                    Text(distanceCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let rssi {
                    Text("\(Int(rssi)) dBm")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("RSSI")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var distanceColor: Color {
        if isStale { return .blue }
        if isOutOfRange { return .orange }
        return .primary
    }

    private var distanceCaption: String {
        if isStale { return "sin datos recientes" }
        if isOutOfRange { return "fuera de rango" }
        return "distancia"
    }

    private var shortId: String {
        String(sensorId.suffix(12))
    }

    private enum SensorStatus: Equatable {
        case notSeen, discovered, outOfRange, stale, connected

        var label: String {
            switch self {
            case .notSeen:    return "No detectado"
            case .discovered: return "Descubierto"
            case .outOfRange: return "Fuera de rango"
            case .stale:      return "Sin datos recientes"
            case .connected:  return "Conectado"
            }
        }

        var color: Color {
            switch self {
            case .notSeen:    return .gray.opacity(0.35)
            case .discovered: return .yellow
            case .outOfRange: return .orange
            case .stale:      return .blue
            case .connected:  return .green
            }
        }
    }
}
