import SwiftUI
import CommonKit
#if os(macOS)
import AppKit
#endif

/// Cloud accounts and which gallery folders sync where.
public struct CloudSettingsView: View {
    @Bindable var cloud: CloudSyncController
    let galleryFolder: URL
    @Environment(\.dismiss) private var dismiss

    public init(cloud: CloudSyncController, galleryFolder: URL) {
        self.cloud = cloud
        self.galleryFolder = galleryFolder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Cloud Sync").font(.title2.bold())
                Spacer()
                CloudStatusBadge(cloud: cloud)
                Button("Done") { dismiss() }
            }
            Text("Artworks are always saved on this device first. Synced folders upload changed layers 10 seconds after you stop drawing (or right away when you switch apps). If two devices edit the same artwork, Paper keeps both as a “Conflicted Copy”.")
                .font(.callout).foregroundStyle(.secondary)

            GroupBox("Accounts") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(cloud.providers) { p in providerRow(p) }
                    if cloud.providers.isEmpty { ProgressView() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox("Synced folders") {
                VStack(alignment: .leading, spacing: 8) {
                    if cloud.folders.isEmpty {
                        Text("None yet. Sign in to an account above, then choose “Sync gallery”.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(cloud.folders) { f in
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            VStack(alignment: .leading) {
                                Text(f.localFolderURL.lastPathComponent).font(.callout.weight(.medium))
                                Text("\(name(of: f.providerID)) · \(f.remoteFolder.description)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop Syncing") { Task { await cloud.disconnect(f.id) } }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Text("Tip: on a Mac with the Google Drive, OneDrive or Dropbox desktop app, you can also pick its folder under Locations in the gallery — no sign-in needed.")
                .font(.caption).foregroundStyle(.secondary)
            if let e = cloud.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Sync Now") { cloud.syncNow() }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
        .task { await cloud.refresh() }
    }

    private func name(of id: CloudProviderID) -> String {
        cloud.providers.first { $0.id == id }?.displayName ?? id.rawValue
    }

    @ViewBuilder
    private func providerRow(_ p: ProviderStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(p.id)).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.displayName).font(.callout.weight(.semibold))
                switch p.authState {
                case .signedIn(let account):
                    Text(account.map { "Signed in as \($0)" } ?? "Signed in").font(.caption).foregroundStyle(.secondary)
                case .signedOut:
                    Text("Not signed in").font(.caption).foregroundStyle(.secondary)
                case .notConfigured(let hint):
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                case .unavailable(let reason):
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            switch p.authState {
            case .signedIn:
                let synced = cloud.folders.contains { $0.providerID == p.id && $0.localFolderURL.standardizedFileURL == galleryFolder.standardizedFileURL }
                if !synced {
                    Button("Sync Gallery") { Task { await cloud.connect(folder: galleryFolder, to: p.id) } }
                }
                if p.id != .iCloudDrive { Button("Sign Out") { Task { await cloud.signOut(p.id) } } }
            case .signedOut:
                Button("Sign In…") { Task { await cloud.signIn(p.id) } }
            case .notConfigured:
                #if os(macOS)
                Button("Set Up Keys…") {
                    if let url = cloud.writeKeysTemplate() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                #endif
            case .unavailable:
                EmptyView()
            }
        }
    }

    private func symbol(_ id: CloudProviderID) -> String {
        switch id {
        case .googleDrive: return "externaldrive.badge.icloud"
        case .dropbox: return "shippingbox"
        case .oneDrive: return "cloud"
        case .iCloudDrive: return "icloud"
        default: return "folder"
        }
    }
}

/// Small status pill: spinning while syncing, warning on problems.
public struct CloudStatusBadge: View {
    let cloud: CloudSyncController
    public init(cloud: CloudSyncController) { self.cloud = cloud }

    public var body: some View {
        HStack(spacing: 6) {
            if cloud.isSyncing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: cloud.lastError == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                    .foregroundStyle(cloud.lastError == nil ? Color.secondary : Color.orange)
            }
            Text(cloud.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(cloud.lastError ?? cloud.statusText)
    }
}
