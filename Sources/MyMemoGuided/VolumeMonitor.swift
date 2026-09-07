import AppKit
import Foundation

struct MountedVolume: Identifiable, Equatable {
    var id: String { url.path }
    let name: String
    let uuid: String?
    let url: URL
    var isManual = false
    var fullVerification = false
}

@MainActor
final class VolumeMonitor {
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?
    func start() {
        guard observers.isEmpty else { return }
        for event in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.onChange?() }
            })
        }
    }

    func mounted() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsLocalKey, .isVolumeKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsInternal != true,
                      values.volumeIsLocal == true, url.path != "/" else { return nil }
                return MountedVolume(name: values.volumeName ?? url.lastPathComponent, uuid: values.volumeUUIDString, url: url)
            }.sorted { $0.name < $1.name }
    }
}
