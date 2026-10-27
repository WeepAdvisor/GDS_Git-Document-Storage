import Foundation

/// Ограничивает параллелизм и паузит запросы после 403/429 (docs/04 §3).
public actor RateLimiter {
    public enum Lane: Sendable, Hashable {
        case read, blobDownload, blobUpload, mutation, graphQL
    }

    private var inFlight: [Lane: Int] = [:]
    private var waiters: [Lane: [CheckedContinuation<Void, Never>]] = [:]
    private var notBefore = Date.distantPast

    public init() {}

    public func acquire(_ lane: Lane) async {
        let delay = notBefore.timeIntervalSinceNow
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        while (inFlight[lane] ?? 0) >= Self.limit(lane) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[lane, default: []].append(continuation)
            }
        }
        inFlight[lane, default: 0] += 1
    }

    public func release(_ lane: Lane) {
        inFlight[lane] = max(0, (inFlight[lane] ?? 1) - 1)
        guard var queue = waiters[lane], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        waiters[lane] = queue
        next.resume()
    }

    public func pause(seconds: TimeInterval) {
        let until = Date().addingTimeInterval(max(seconds, 1))
        if until > notBefore { notBefore = until }
    }

    private static func limit(_ lane: Lane) -> Int {
        switch lane {
        case .read: return 8
        case .blobDownload: return 6
        case .blobUpload: return 4
        case .mutation, .graphQL: return 1
        }
    }
}
