import SwiftUI

struct PanelServiceUsage: View {
    let service: ModelService
    let status: ServiceUsageBoard.Status

    var body: some View {
        PanelSectionTitle(text: service == .zai ? "Z.ai Coding Plan" : "DeepSeek") {
            if case .ready(_, let measuredAt) = status {
                Text(measuredAt.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        switch status {
        case .ready(let usage, _):
            PanelCard {
                VStack(spacing: 0) {
                    ForEach(Array(usage.metrics.enumerated()), id: \.offset) { i, metric in
                        if i > 0 { PanelHairline() }
                        metricRow(metric)
                    }
                }
            }
        case .failed(let error):
            PanelNotice(glyph: "exclamationmark.circle", text: error.message)
                .help(error.message)
        case .keySaved:
            PanelNotice(glyph: "hourglass", text: "Waiting for the first account check")
        case .unknown, .notConfigured:
            EmptyView()
        }
    }

    private func metricRow(_ metric: ModelServiceUsage.Metric) -> some View {
        HStack(spacing: 6) {
            Text(metric.title)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let reset = metric.resetAt, reset > Date() {
                Text("in " + StatusController.until(reset.timeIntervalSince1970))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Resets " + reset.formatted(date: .abbreviated, time: .shortened))
            }
            Text(metric.value)
                .fontWeight(.medium)
                .monospacedDigit()
                .fixedSize()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
