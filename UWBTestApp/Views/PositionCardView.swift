//
//  PositionCardView.swift
//  UWBTestApp
//
import SwiftUI

/// Shows the raw trilateration output next to the Kalman-filtered one, plus the fix
/// quality the plugin exposes to Unity through `getPositionData`. The gap between the
/// two columns is the filter's contribution: small while standing still, larger (as
/// lag) during fast movement — that is the number to watch when tuning R and Q.
struct PositionCardView: View {
    let filtered: Vector2D?
    let raw: Vector2D?
    let residual: Double?
    /// Anchors that fed the last fix — a property of that fix, so it stays put while
    /// the fix ages.
    let activeAnchors: Int
    /// Anchors eligible right now; drives the "waiting" message before the first fix.
    let feedingSensors: Int
    let fixTimestamp: TimeInterval?

    var body: some View {
        if let filtered {
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    positionColumn(title: "Filtrado", position: filtered, emphasized: true)
                    Divider().padding(.vertical, 4)
                    positionColumn(title: "Crudo", position: raw, emphasized: false)
                }
                Divider()
                qualityRow
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
                Text(waitingMessage)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Pieces

    private func positionColumn(title: String, position: Vector2D?, emphasized: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let position {
                Text(String(format: "%.3f", position.x))
                    .font(.system(emphasized ? .title3 : .body, design: .monospaced))
                    .bold(emphasized)
                Text(String(format: "%.3f", position.y))
                    .font(.system(emphasized ? .title3 : .body, design: .monospaced))
                    .bold(emphasized)
                    .foregroundStyle(emphasized ? .primary : .secondary)
            } else {
                Text("—").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(emphasized ? .primary : .secondary)
        .frame(maxWidth: .infinity)
    }

    private var qualityRow: some View {
        // The fix age keeps growing without new measurements, so it needs its own clock
        // rather than waiting for the next telemetry push.
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 14) {
                metric(label: "residual",
                       value: residual.map { String(format: "%.2f m", $0) } ?? "—",
                       color: residualColor)
                metric(label: "anclas", value: "\(activeAnchors)",
                       color: activeAnchors >= 4 ? .green : (activeAnchors >= 3 ? .orange : .red))
                let age = fixTimestamp.map { context.date.timeIntervalSince1970 - $0 }
                metric(label: "edad",
                       value: age.map { String(format: "%.1f s", max(0, $0)) } ?? "—",
                       color: ageColor(age))
                if let delta = rawFilteredDelta {
                    metric(label: "Δ filtro", value: String(format: "%.2f m", delta), color: .secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func metric(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .bold()
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Derived values

    /// Distance between the raw fix and the filtered one.
    private var rawFilteredDelta: Double? {
        guard let filtered, let raw else { return nil }
        let dx = filtered.x - raw.x
        let dy = filtered.y - raw.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private var residualColor: Color {
        guard let residual else { return .secondary }
        if residual < 0.3 { return .green }
        if residual < 0.8 { return .orange }
        return .red
    }

    private func ageColor(_ age: Double?) -> Color {
        guard let age else { return .secondary }
        if age < 1.0 { return .green }
        if age < 3.0 { return .orange }
        return .red
    }

    private var waitingMessage: String {
        let needed = max(0, 3 - feedingSensors)
        if needed == 0 {
            return "Calculando posicion..."
        } else if needed == 1 {
            return "Necesita 1 sensor mas"
        } else {
            return "Necesita \(needed) sensores mas"
        }
    }
}
