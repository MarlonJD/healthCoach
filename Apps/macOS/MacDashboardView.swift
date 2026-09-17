import SwiftUI
import HealthCoachKit
import CoreImage

struct MacDashboardView: View {
    @ObservedObject var model: MacAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("HealthCoach").font(.largeTitle.bold())
                        Text("Local Mac companion").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(model.codexStatus.readiness == .ready ? .green : .orange).frame(width: 12, height: 12)
                }
                GroupBox("Pairing") {
                    HStack(alignment: .top, spacing: 20) {
                        if let payload = model.qrPayload {
                            PairingQRCodeView(payload: payload).frame(width: 190, height: 190)
                        } else {
                            Image(systemName: "checkmark.shield").font(.system(size: 72)).foregroundStyle(.green).frame(width: 190, height: 190)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.qrPayload == nil ? "iPhone paired" : "Scan this QR from the iPhone Settings tab")
                                .font(.headline)
                            Text("Only a random credential, pair ID, and short expiry are encoded. Health data is not advertised in Bonjour.")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let credential = model.pairingCredential, model.qrPayload != nil {
                                Text("This QR refreshes automatically before it expires.")
                                    .font(.footnote)
                                Text("Current code expires \(credential.expiresAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(model.syncStatus).font(.footnote)
                            if model.qrPayload == nil { Button("Unpair and create new QR", role: .destructive) { model.unpair() } }
                        }
                    }
                }
                GroupBox("Codex host") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(title: "Readiness", value: model.codexStatus.readiness.rawValue, systemImage: "cpu")
                        StatusRow(title: "Model", value: model.codexStatus.modelID ?? "gpt-5.6-luna", systemImage: "sparkles")
                        StatusRow(title: "Reasoning", value: model.codexStatus.reasoningEffort ?? "max", systemImage: "dial.medium")
                        if let path = model.codexStatus.executablePath { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Text("Each automatic job verifies the effective read-only HealthCoach MCP catalog before dispatch. The App Server uses an app-specific CODEX_HOME; global Codex settings are not changed.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let error = model.codexStatus.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                        Toggle("Pause automatic analysis on this Mac", isOn: Binding(get: { model.analysisPaused }, set: { _ in model.toggleAnalysisPause() }))
                        Button("Run queued jobs") { model.runWorker() }
                    }
                }
                GroupBox("Sync and jobs") {
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(title: "Pending jobs", value: "\(model.jobs.filter { $0.status == .queued || $0.status == .running }.count)", systemImage: "clock")
                        StatusRow(title: "Dead-lettered", value: "\(model.jobs.filter { $0.status == .deadLettered }.count)", systemImage: "exclamationmark.triangle")
                        StatusRow(title: "Pending reverse sync", value: "\(model.pendingReverseSyncCount)", systemImage: "arrow.up.circle")
                        StatusRow(title: "Last sync", value: model.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet", systemImage: "arrow.triangle.2.circlepath")
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(model.jobs.prefix(5)) { job in
                                    HStack {
                                        Text(job.kind.rawValue)
                                        Spacer()
                                        Text(jobStatusTitle(job.status)).foregroundStyle(.secondary)
                                    }
                                    .font(.footnote)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 112)
                        .scrollIndicators(.visible)
                        .overlay {
                            if model.jobs.isEmpty {
                                Text("No jobs yet.").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                GroupBox("Preferences") {
                    Toggle("Launch at login", isOn: $model.launchAtLogin)
                    Text("The companion reconnects while running and uses opportunistic macOS networking. iOS background execution remains subject to system limits.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(24)
        }
    }

    private func jobStatusTitle(_ status: JobStatus) -> String {
        status == .deadLettered ? "Dead-lettered" : status.rawValue.capitalized
    }
}

private struct StatusRow: View {
    let title: String
    let value: String
    var systemImage: String = "circle.fill"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(Color.accentColor)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

private struct PairingQRCodeView: View {
    let payload: Data

    var body: some View {
        if let image = makeImage() {
            Image(image, scale: 1, orientation: .up, label: Text("HealthCoach pairing QR"))
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(8)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Text("QR unavailable")
        }
    }

    private func makeImage() -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(payload, forKey: "inputMessage")
        filter.setValue("Q", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), from: output.extent.applying(CGAffineTransform(scaleX: 8, y: 8)))
    }
}
