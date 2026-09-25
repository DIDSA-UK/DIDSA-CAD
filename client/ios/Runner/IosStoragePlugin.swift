import Flutter
import UIKit
import UniformTypeIdentifiers

/// Bridges the client's storage abstraction (see
/// client/lib/storage/ios_storage_service.dart /
/// client/lib/storage/ios_bookmark_channel.dart) to iOS's security-scoped
/// bookmark APIs. iOS has no Storage Access Framework equivalent to
/// Android's - persisted access to a user-picked folder across app
/// launches instead relies on `URL.bookmarkData` /
/// `URL(resolvingBookmarkData:...)`, bracketed by
/// `start/stopAccessingSecurityScopedResource()`.
///
/// Deliberately NOT `.withSecurityScope` on `bookmarkData`'s options -
/// that option is macOS-only and does not exist on iOS. The plain,
/// option-less form (`options: []`) is the correct iOS call.
///
/// No entitlements or Info.plist changes are required: iOS has no App
/// Sandbox concept, and `UIDocumentPickerViewController(forOpeningContentTypes:
/// [.folder])` uses the system `.folder` UTType with no app-side
/// declaration needed.
class IosStoragePlugin: NSObject {
    static let channelName = "uk.snail_shell.didsa_cad_client/ios_storage"

    /// Every resolved root currently held open, keyed by its resolved
    /// filesystem path, ref-counted so two concurrent Dart-side calls that
    /// both resolved the same root don't have the first one's
    /// `stopAccessing` close the scope out from under the second - see
    /// `resolveBookmark`/`stopAccessing` below. The stored `URL` is the
    /// exact instance `start/stopAccessingSecurityScopedResource()` must be
    /// paired against.
    private var accessedURLs: [String: (url: URL, count: Int)] = [:]

    private weak var presentingViewController: UIViewController?
    private var pendingPickResult: FlutterResult?

    init(viewController: UIViewController) {
        self.presentingViewController = viewController
    }

    func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: IosStoragePlugin.channelName, binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "pickFolder":
            pickFolder(result: result)

        case "resolveBookmark":
            guard let bookmarkBase64 = args?["bookmarkBase64"] as? String else {
                result(FlutterError(code: "bad_args", message: "bookmarkBase64 is required", details: nil))
                return
            }
            resolveBookmark(bookmarkBase64: bookmarkBase64, result: result)

        case "stopAccessing":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "bad_args", message: "path is required", details: nil))
                return
            }
            stopAccessing(path: path)
            result(nil)

        case "readFile":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "bad_args", message: "path is required", details: nil))
                return
            }
            readFile(path: path, result: result)

        case "writeFile":
            guard let path = args?["path"] as? String, let bytes = args?["bytes"] as? FlutterStandardTypedData else {
                result(FlutterError(code: "bad_args", message: "path and bytes are required", details: nil))
                return
            }
            writeFile(path: path, data: bytes.data, result: result)

        case "renameFile":
            guard let path = args?["path"] as? String, let newFileName = args?["newFileName"] as? String else {
                result(FlutterError(code: "bad_args", message: "path and newFileName are required", details: nil))
                return
            }
            renameFile(path: path, newFileName: newFileName, result: result)

        case "lastModifiedMs":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "bad_args", message: "path is required", details: nil))
                return
            }
            result(lastModifiedMs(path: path))

        case "exists":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "bad_args", message: "path is required", details: nil))
                return
            }
            result(FileManager.default.fileExists(atPath: path))

        case "listFilesRecursive":
            guard let rootPath = args?["rootPath"] as? String else {
                result(FlutterError(code: "bad_args", message: "rootPath is required", details: nil))
                return
            }
            let extensionFilter = args?["extensionFilter"] as? String
            result(listFilesRecursive(rootPath: rootPath, extensionFilter: extensionFilter))

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Folder picking

    private func pickFolder(result: @escaping FlutterResult) {
        guard let presentingViewController = presentingViewController else {
            result(FlutterError(code: "no_view_controller", message: "No presenting view controller", details: nil))
            return
        }
        guard pendingPickResult == nil else {
            result(FlutterError(code: "pick_in_progress", message: "A folder pick is already in progress", details: nil))
            return
        }
        pendingPickResult = result
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        presentingViewController.present(picker, animated: true)
    }

    // MARK: - Bookmark resolve/access

    private func resolveBookmark(bookmarkBase64: String, result: @escaping FlutterResult) {
        guard let bookmarkData = Data(base64Encoded: bookmarkBase64) else {
            result(nil)
            return
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let path = url.path
            if let existing = accessedURLs[path] {
                // Already held open by another in-flight call against the
                // same resolved root - just bump the ref count, don't call
                // startAccessingSecurityScopedResource again.
                accessedURLs[path] = (existing.url, existing.count + 1)
            } else {
                guard url.startAccessingSecurityScopedResource() else {
                    result(nil)
                    return
                }
                accessedURLs[path] = (url, 1)
            }
            result(["path": path, "isStale": isStale])
        } catch {
            result(nil)
        }
    }

    private func stopAccessing(path: String) {
        guard let existing = accessedURLs[path] else { return }
        if existing.count <= 1 {
            existing.url.stopAccessingSecurityScopedResource()
            accessedURLs.removeValue(forKey: path)
        } else {
            accessedURLs[path] = (existing.url, existing.count - 1)
        }
    }

    // MARK: - File I/O
    //
    // These operate on an already-resolved path - the security-scoped
    // access around it was opened by resolveBookmark and is released by a
    // later stopAccessing call from the Dart side, not by these methods
    // themselves.

    private func readFile(path: String, result: @escaping FlutterResult) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            result(FlutterStandardTypedData(bytes: data))
        } catch {
            result(FlutterError(code: "read_failed", message: "Failed to read \(path)", details: "\(error)"))
        }
    }

    private func writeFile(path: String, data: Data, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            result(nil)
        } catch {
            result(FlutterError(code: "write_failed", message: "Failed to write \(path)", details: "\(error)"))
        }
    }

    /// Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
    /// §3.2): the assembly tree's own Rename action - renames the file at
    /// `path` to `newFileName`, keeping it in the same directory (a plain
    /// `moveItem` within one parent, mirroring `SafStorageService`'s own
    /// same-directory-only `renameFile` contract). Returns the new full
    /// path on success, so the caller can compute the new relative path
    /// itself the same way `writeFile`'s own caller already does.
    private func renameFile(path: String, newFileName: String, result: @escaping FlutterResult) {
        let sourceURL = URL(fileURLWithPath: path)
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent(newFileName)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            result(destinationURL.path)
        } catch {
            result(FlutterError(code: "rename_failed", message: "Failed to rename \(path)", details: "\(error)"))
        }
    }

    private func lastModifiedMs(path: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let modified = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        return Int64(modified.timeIntervalSince1970 * 1000)
    }

    // MARK: - Recursive listing

    /// Every file (never directories) under `rootPath`, as POSIX-relative
    /// paths from `rootPath`, best-effort: a subtree the enumerator can't
    /// read (permission error, broken entry) is skipped rather than
    /// failing the whole walk - `errorHandler` below always returns `true`
    /// to keep enumerating past the failing entry, matching
    /// `StorageService.listFiles`'s own "best-effort per subtree" contract
    /// (`client/lib/storage/storage_service.dart`).
    private func listFilesRecursive(rootPath: String, extensionFilter: String?) -> [String] {
        let rootURL = URL(fileURLWithPath: rootPath)
        var results: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            )
        else {
            return results
        }
        let rootPrefix = rootURL.path
        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys))
            if resourceValues?.isDirectory == true { continue }
            guard fileURL.path.hasPrefix(rootPrefix) else { continue }
            let relativePath = String(fileURL.path.dropFirst(rootPrefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relativePath.isEmpty { continue }
            if let extensionFilter = extensionFilter, !fileURL.lastPathComponent.hasSuffix(extensionFilter) {
                continue
            }
            results.append(relativePath)
        }
        return results
    }
}

extension IosStoragePlugin: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let result = pendingPickResult else { return }
        pendingPickResult = nil
        guard let url = urls.first else {
            result(nil)
            return
        }
        // Bracketed just around bookmark creation itself - the resulting
        // bookmark is what gets persisted, not an open access grant; a
        // later resolveBookmark call opens (and ref-counts) the real
        // session-scoped access whenever the app actually needs to touch
        // files under this root.
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let bookmarkData = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let bookmarkBase64 = bookmarkData.base64EncodedString()
            result(["bookmarkBase64": bookmarkBase64, "displayName": url.lastPathComponent])
        } catch {
            result(
                FlutterError(
                    code: "bookmark_failed",
                    message: "Failed to create a bookmark for the picked folder",
                    details: "\(error)"
                )
            )
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let result = pendingPickResult else { return }
        pendingPickResult = nil
        result(nil)
    }
}
