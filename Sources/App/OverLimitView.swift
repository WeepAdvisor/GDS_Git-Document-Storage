import SwiftUI
import SyncCore

struct OverLimitView: View {
    @State private var files: [OversizedFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These files stay in the folder and will not be uploaded. GitHub accepts at most 100 MB per file.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if files.isEmpty {
                ContentUnavailableView("Nothing over the limit", systemImage: "checkmark.circle")
            } else {
                List(files) { file in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileName(file.path)).font(.headline)
                            Text("\(file.domainName)  ·  \(file.path)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(byteText(file.bytes))
                            .font(.callout.monospacedDigit())
                        Button("Show in Finder") {
                            Task { await DomainManager.shared.reveal(domainID: file.domainID, itemID: file.id, path: file.path) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { files = LimitReport.refresh() }
    }

    private func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func byteText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
