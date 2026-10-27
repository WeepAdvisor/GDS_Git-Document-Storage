import Foundation

public enum SyncDirection: String, Codable, Sendable {
    case upload
    case download
}

/// Снимок одного бара в меню.
public struct SyncMeter: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case idle
        case files
        case bytes
    }

    public var kind: Kind
    public var done: Int64
    public var total: Int64
    public var percent: Int
    public var fraction: Double

    public var caption: String {
        switch kind {
        case .idle:
            return "Up to date"
        case .files:
            if done == 0, total == 1 { return "Fetching…" }
            return "\(done) of \(total) files"
        case .bytes:
            return "\(Self.format(done)) of \(Self.format(total))"
        }
    }

    public static let idle = SyncMeter(kind: .idle, done: 0, total: 0, percent: 100, fraction: 1)

    static func make(filesDone: Int64, filesTotal: Int64, bytesDone: Int64, bytesTotal: Int64) -> SyncMeter {
        if bytesTotal > 0 {
            return make(done: bytesDone, total: bytesTotal, kind: .bytes)
        }
        if filesTotal > 0 {
            return make(done: filesDone, total: filesTotal, kind: .files)
        }
        return .idle
    }

    private static func make(done: Int64, total: Int64, kind: Kind) -> SyncMeter {
        let safeTotal = max(total, 1)
        let clamped = min(max(done, 0), safeTotal)
        let fraction = min(1, Double(clamped) / Double(safeTotal))
        let percent = Int((fraction * 100).rounded(.down))
        return SyncMeter(kind: kind, done: clamped, total: safeTotal, percent: percent, fraction: fraction)
    }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Прогресс выгрузки и скачивания по доменам. Пишет расширение, читает меню.
public enum SyncActivity {
    public struct Pair: Equatable, Sendable {
        public var download: SyncMeter
        public var upload: SyncMeter
    }

    private struct Slice: Codable, Equatable {
        var filesDone: Int64 = 0
        var filesTotal: Int64 = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        var at: TimeInterval = 0
    }

    private struct Record: Codable, Equatable {
        var upload = Slice()
        var download = Slice()
    }

    private static let key = "syncActivity"
    private static let lock = NSLock()
    private static let stale: TimeInterval = 120
    private static let linger: TimeInterval = 2

    public static func setFiles(domain: UUID, direction: SyncDirection, done: Int64, total: Int64, defaults: UserDefaults? = nil, now: Date = Date()) {
        mutate(domain: domain, direction: direction, defaults: defaults) { slice in
            if done == 0, total > 0 {
                slice.bytesDone = 0
                slice.bytesTotal = 0
            }
            slice.filesDone = done
            slice.filesTotal = total
            slice.at = now.timeIntervalSince1970
        }
    }

    public static func setBytes(domain: UUID, direction: SyncDirection, done: Int64, total: Int64, defaults: UserDefaults? = nil, now: Date = Date()) {
        mutate(domain: domain, direction: direction, defaults: defaults) { slice in
            slice.bytesDone = done
            slice.bytesTotal = total
            slice.at = now.timeIntervalSince1970
        }
    }

    public static func current(defaults: UserDefaults? = nil, now: Date = Date()) -> Pair {
        let records = load(defaults: defaults)
        return combine(records: records, now: now)
    }

    private static func combine(records: [String: Record], now: Date) -> Pair {
        Pair(
            download: meter(records.map(\.value.download), now: now),
            upload: meter(records.map(\.value.upload), now: now)
        )
    }

    private static func meter(_ slices: [Slice], now: Date) -> SyncMeter {
        let nowStamp = now.timeIntervalSince1970
        var filesDone: Int64 = 0
        var filesTotal: Int64 = 0
        var bytesDone: Int64 = 0
        var bytesTotal: Int64 = 0
        for slice in slices {
            guard slice.at > 0, nowStamp - slice.at < stale else { continue }
            let filesFinished = slice.filesTotal > 0 && slice.filesDone >= slice.filesTotal
            let bytesFinished = slice.bytesTotal > 0 && slice.bytesDone >= slice.bytesTotal
            let quiet = nowStamp - slice.at > linger
            if quiet, filesFinished, slice.bytesTotal == 0 { continue }
            if quiet, bytesFinished, slice.filesTotal == 0 { continue }
            if quiet, filesFinished, bytesFinished { continue }
            filesDone += slice.filesDone
            filesTotal += slice.filesTotal
            bytesDone += slice.bytesDone
            bytesTotal += slice.bytesTotal
        }
        return SyncMeter.make(filesDone: filesDone, filesTotal: filesTotal, bytesDone: bytesDone, bytesTotal: bytesTotal)
    }

    private static func mutate(domain: UUID, direction: SyncDirection, defaults: UserDefaults?, now: Date = Date(), change: (inout Slice) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let store = defaults ?? (try? SharedPaths())?.userDefaults
        guard let store else { return }
        var records = decode(store.data(forKey: key))
        var record = records[domain.uuidString] ?? Record()
        switch direction {
        case .upload: change(&record.upload)
        case .download: change(&record.download)
        }
        records[domain.uuidString] = record
        if let data = try? JSONEncoder().encode(records) {
            store.set(data, forKey: key)
            store.synchronize()
        }
    }

    private static func load(defaults: UserDefaults?) -> [String: Record] {
        lock.lock()
        defer { lock.unlock() }
        let store = defaults ?? (try? SharedPaths())?.userDefaults
        guard let store else { return [:] }
        return decode(store.data(forKey: key))
    }

    private static func decode(_ data: Data?) -> [String: Record] {
        guard let data else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }
}
