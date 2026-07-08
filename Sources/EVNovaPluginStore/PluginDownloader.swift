import Foundation

public enum PluginDownloadError: Error, LocalizedError {
    case badStatus(Int)
    case tooSmall(Int)
    case noLocalFile

    public var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Download failed (HTTP \(code))."
        case .tooSmall(let bytes): return "Downloaded file was only \(bytes) bytes — likely a broken link, not the real plug-in."
        case .noLocalFile: return "Download finished but no file was produced."
        }
    }
}

/// Downloads a plug-in archive from its original host, streaming to a temp
/// file with progress. Never mirrors/redistributes the file itself — the URL
/// always points at the source the plug-in author actually published to.
public enum PluginDownloader {
    /// Below this size a "download" is almost certainly a broken link or (for
    /// the GitHub-Pages/LFS-backed host) an LFS pointer stub rather than the
    /// real archive — same guard `scripts/fetch-plugins.sh` uses.
    public static let minimumValidBytes = 1000

    /// Downloads `url` to a new temp file via a `URLSessionDownloadTask`,
    /// reporting fractional progress (0...1, or `nil` if the server didn't
    /// send a size). Returns the temp file URL on success; throws and cleans
    /// up on failure. `onProgress` may be called from a background queue.
    public static func download(
        from url: URL,
        onProgress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> URL {
        let delegate = DownloadDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double?) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(onProgress: @escaping @Sendable (Double?) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                         didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                         totalBytesExpectedToWrite: Int64) {
            onProgress(totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                         didFinishDownloadingTo location: URL) {
            guard let continuation else { return }
            self.continuation = nil
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                continuation.resume(throwing: PluginDownloadError.badStatus(http.statusCode))
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? nil
            guard let size, size >= PluginDownloader.minimumValidBytes else {
                continuation.resume(throwing: PluginDownloadError.tooSmall(size ?? 0))
                return
            }
            // `location` is deleted as soon as this method returns — move it now.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("zip")
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                continuation.resume(returning: dest)
            } catch {
                continuation.resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: error)
        }
    }
}
