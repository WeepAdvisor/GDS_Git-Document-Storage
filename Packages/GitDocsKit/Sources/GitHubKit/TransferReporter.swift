import Foundation

public enum TransferDirection: Sendable {
    case upload
    case download
}

/// Суммирует прогресс параллельных запросов одного `GitHubClient` и отдаёт байты наружу.
public final class TransferReporter: @unchecked Sendable {
    public var onChange: (@Sendable (TransferDirection, Int64, Int64) -> Void)?

    private let lock = NSLock()
    private var uploads: [Int: (Int64, Int64)] = [:]
    private var downloads: [Int: (Int64, Int64)] = [:]
    private var lastNote: [TransferDirection: TimeInterval] = [:]

    public init() {}

    func note(task: Int, direction: TransferDirection, done: Int64, total: Int64) {
        let expected = total > 0 ? total : max(done, 1)
        let snapshot: (Int64, Int64)
        let callback: (@Sendable (TransferDirection, Int64, Int64) -> Void)?
        lock.lock()
        switch direction {
        case .upload: uploads[task] = (done, expected)
        case .download: downloads[task] = (done, expected)
        }
        snapshot = Self.sum(direction == .upload ? uploads : downloads)
        let now = Date().timeIntervalSince1970
        let finished = snapshot.0 >= snapshot.1 && snapshot.1 > 0
        if !finished, now - (lastNote[direction] ?? 0) < 0.1 {
            lock.unlock()
            return
        }
        lastNote[direction] = now
        callback = onChange
        lock.unlock()
        callback?(direction, snapshot.0, snapshot.1)
    }

    func finish(task: Int) {
        let callback: (@Sendable (TransferDirection, Int64, Int64) -> Void)?
        var updates: [(TransferDirection, Int64, Int64)] = []
        lock.lock()
        if uploads[task] != nil {
            uploads[task] = nil
            let sum = Self.sum(uploads)
            updates.append((.upload, sum.0, sum.1))
        }
        if downloads[task] != nil {
            downloads[task] = nil
            let sum = Self.sum(downloads)
            updates.append((.download, sum.0, sum.1))
        }
        callback = onChange
        lock.unlock()
        for update in updates {
            callback?(update.0, update.1, update.2)
        }
    }

    private static func sum(_ values: [Int: (Int64, Int64)]) -> (Int64, Int64) {
        values.values.reduce((0, 0)) { ($0.0 + $1.0, $0.1 + $1.1) }
    }
}

/// Наблюдатель одного запроса. Не забирает тело ответа у `URLSession`.
final class TransferTaskDelegate: NSObject, URLSessionTaskDelegate {
    private let reporter: TransferReporter

    init(reporter: TransferReporter) {
        self.reporter = reporter
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        reporter.note(task: task.taskIdentifier, direction: .upload, done: totalBytesSent, total: totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        reporter.finish(task: task.taskIdentifier)
    }
}

/// Скачивание в файл с промежуточными байтами. Свой `URLSession`, потому что прогресс download-задачи живёт только в делегате сессии.
final class ByteDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let reporter: TransferReporter?
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var moved: URL?
    private var response: HTTPURLResponse?
    private var resumed = false
    private let lock = NSLock()

    init(reporter: TransferReporter?) {
        self.reporter = reporter
    }

    func start(request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        reporter?.note(task: downloadTask.taskIdentifier, direction: .download, done: totalBytesWritten, total: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = FileManager.default.temporaryDirectory.appending(path: "gds-dl-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            moved = destination
            response = downloadTask.response as? HTTPURLResponse
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        reporter?.finish(task: task.taskIdentifier)
        if let error {
            finish(.failure(error))
            return
        }
        guard let moved, let response else {
            finish(.failure(GitHubError.network("Missing download")))
            return
        }
        finish(.success((moved, response)))
    }

    private func finish(_ result: Result<(URL, HTTPURLResponse), Error>) {
        lock.lock()
        guard !resumed, let continuation else {
            lock.unlock()
            return
        }
        resumed = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
