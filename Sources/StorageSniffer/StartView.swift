import AppKit
import SwiftUI
import SnifferCore

/// First screen: pick what to scan and check Full Disk Access.
struct StartView: View {
    @Environment(AppModel.self) private var model
    private let disk = VolumeInfo(path: "/")

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                Text("Where did my space go?")
                    .font(.largeTitle.weight(.semibold))
                Text("Scan a disk or folder to see what’s taking up room.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                ChoiceCard(icon: "internaldrive.fill", title: disk?.name ?? "Macintosh HD",
                           subtitle: "Everything on your Mac", disk: disk) {
                    model.startScan(path: "/")
                }
                ChoiceCard(icon: "house.fill", title: "Home Folder",
                           subtitle: "Your files, apps’ data, caches and downloads", disk: nil) {
                    model.startScan(path: NSHomeDirectory())
                }
                ChoiceCard(icon: "folder.fill.badge.gearshape", title: "Choose Folder…",
                           subtitle: "Any folder or external drive", disk: nil) {
                    chooseFolder()
                }
            }
            .frame(maxWidth: 820)

            AccessStatus()
                .frame(maxWidth: 820)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or drive to scan"
        if panel.runModal() == .OK, let url = panel.url {
            model.startScan(path: url.path)
        }
    }
}

private struct ChoiceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let disk: VolumeInfo?
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(height: 30)
                Text(title).font(.headline)
                if let disk {
                    UsageBar(used: disk.used, total: disk.total)
                    Text("\(Format.bytes(disk.used)) used of \(Format.bytes(disk.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
            .background(.quaternary.opacity(hovering ? 0.9 : 0.5), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: 1)
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.snappy(duration: 0.18), value: hovering)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct UsageBar: View {
    let used: Int64
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.accentColor.gradient)
                    .frame(width: geo.size.width * (total > 0 ? Double(used) / Double(total) : 0))
            }
        }
        .frame(height: 8)
    }
}

private struct AccessStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.title2)
                .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.hasFullDiskAccess ? "Full Disk Access is on" : "Full Disk Access is off")
                    .font(.headline)
                Text(model.hasFullDiskAccess
                     ? "Scans can see everything, including Mail, Messages, Photos and other apps’ data."
                     : "Without it, macOS hides Mail, Messages, Safari and other apps’ data, so totals come out low and you may see several permission prompts. Turn on Storage Sniffer in System Settings, then reopen the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !model.hasFullDiskAccess {
                Button("Open Settings") { FullDiskAccess.openSettings() }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
    }
}

enum FullDiskAccess {
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
