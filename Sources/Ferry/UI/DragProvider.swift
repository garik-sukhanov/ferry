import AppKit
import UniformTypeIdentifiers

/// Builds the item provider Finder receives when a row is dragged out.
/// Nothing is fetched until the drop actually happens: Finder calls the handler,
/// we stage the file in a temp folder and hand back its URL. On APFS the copy
/// that follows is a clone, so staging costs no extra disk.
enum DragProvider {
    static func provider(for file: RemoteFile, session: Session) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name

        let type = file.looksLikeDirectory
            ? UTType.folder.identifier
            : (UTType(filenameExtension: (file.name as NSString).pathExtension)?.identifier
               ?? UTType.data.identifier)

        provider.registerFileRepresentation(forTypeIdentifier: type,
                                            fileOptions: [],
                                            visibility: .all) { completion in
            let progress = Progress(totalUnitCount: max(file.size, 1))

            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ferry-drag-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let target = staging.appendingPathComponent(file.name)

            Task { @MainActor in
                session.stageForDrag(file, to: target, progress: progress) { result in
                    switch result {
                    case .success(let url): completion(url, false, nil)
                    case .failure(let error): completion(nil, false, error)
                    }
                }
            }
            return progress
        }
        return provider
    }
}
