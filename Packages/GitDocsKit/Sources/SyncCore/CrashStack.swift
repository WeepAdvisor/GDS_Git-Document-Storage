import Darwin
import Foundation

/// Стек падения пишется в момент сигнала, на запасном стеке. MetricKit при переполнении
/// главного стека отдаёт пустые кадры — этот файл их заменяет на следующем запуске.
enum CrashStack {
    private struct Image {
        var start: UInt64
        var end: UInt64
        var path: UnsafePointer<CChar>
    }

    private static let frameLimit = 64
    private static let lineCapacity = 1280

    nonisolated(unsafe) private static var images: UnsafeMutableBufferPointer<Image>?
    nonisolated(unsafe) private static var fileDescriptor: Int32 = -1
    nonisolated(unsafe) private static var alternate: UnsafeMutableRawPointer?
    nonisolated(unsafe) private static var line = UnsafeMutablePointer<UInt8>.allocate(capacity: lineCapacity)
    nonisolated(unsafe) private static var frames = UnsafeMutablePointer<UInt64>.allocate(capacity: frameLimit)
    nonisolated(unsafe) private static var entered = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    nonisolated(unsafe) private static var installed = false

    /// Текст стека прошлого вылета. Файл потом обнуляет `install`.
    static func consumePending(process: String, container: URL? = nil) -> String? {
        guard let url = fileURL(process: process, container: container),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        let text = render(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func install(process: String, container: URL? = nil) {
        guard !installed, let url = fileURL(process: process, container: container) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        entered.initialize(to: 0)
        snapshotImages()
        guard installAlternateStack(), installHandlers() else { return }
        installed = true
    }

    /// Кадры из JSON `MXCallStackTree` — читаемый текст, без сырого дерева.
    static func formatMetricKit(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stacks = root["callStacks"] as? [[String: Any]] else { return "" }
        var lines: [String] = []
        for (index, stack) in stacks.enumerated() {
            let crashed = stack["threadAttributed"] as? Bool ?? false
            let roots = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            var frames: [String] = []
            for root in roots {
                flatten(root, into: &frames)
            }
            let title = crashed ? "thread \(index) crashed" : "thread \(index)"
            if frames.isEmpty {
                if crashed { lines.append("\(title)\n  no frames") }
                continue
            }
            lines.append(title)
            let limit = crashed ? frameLimit : 12
            for (number, frame) in frames.prefix(limit).enumerated() {
                lines.append("  \(number) \(frame)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func collect(pc: UInt64, lr: UInt64, fp: UInt64, read: (UInt64) -> UInt64?) -> [UInt64] {
        let count = fill(pc: pc, lr: lr, fp: fp, into: frames, capacity: frameLimit, read: read)
        return Array(UnsafeBufferPointer(start: frames, count: count))
    }

    static func formatFrames(_ pcs: [UInt64], images list: [(start: UInt64, end: UInt64, name: String)]) -> [String] {
        pcs.map { pc in
            if let image = list.first(where: { pc >= $0.start && pc < $0.end }) {
                return "\(image.name) + 0x\(String(pc - image.start, radix: 16))"
            }
            return "??? + 0x\(String(pc, radix: 16))"
        }
    }

    private static func fileURL(process: String, container: URL?) -> URL? {
        guard let root = container ?? (try? SharedPaths())?.containerURL else { return nil }
        return root.appending(path: "Library/Application Support").appending(path: "crash-stack-\(process).txt")
    }

    private static func snapshotImages() {
        let count = Int(_dyld_image_count())
        let buffer = UnsafeMutableBufferPointer<Image>.allocate(capacity: max(count, 1))
        var stored = 0
        for index in 0..<count {
            guard let header = _dyld_get_image_header(UInt32(index)),
                  let path = _dyld_get_image_name(UInt32(index)) else { continue }
            let slide = UInt64(bitPattern: Int64(_dyld_get_image_vmaddr_slide(UInt32(index))))
            let start = UInt64(UInt(bitPattern: header))
            buffer[stored] = Image(start: start, end: imageEnd(header, slide: slide, fallback: start), path: path)
            stored += 1
        }
        images = UnsafeMutableBufferPointer(start: buffer.baseAddress, count: stored)
    }

    private static func imageEnd(_ header: UnsafePointer<mach_header>, slide: UInt64, fallback: UInt64) -> UInt64 {
        guard header.pointee.magic == MH_MAGIC_64 else { return fallback &+ 0x1000 }
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var end = fallback
        for _ in 0..<Int(header64.pointee.ncmds) {
            let load = command.assumingMemoryBound(to: load_command.self)
            if load.pointee.cmd == UInt32(LC_SEGMENT_64) {
                let segment = command.assumingMemoryBound(to: segment_command_64.self)
                let segmentEnd = segment.pointee.vmaddr &+ segment.pointee.vmsize &+ slide
                if segmentEnd > end { end = segmentEnd }
            }
            let size = Int(load.pointee.cmdsize)
            if size <= 0 { break }
            command = command.advanced(by: size)
        }
        return end > fallback ? end : fallback &+ 0x1000
    }

    private static func installAlternateStack() -> Bool {
        let size = 64 * 1024
        let memory = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        var stack = stack_t()
        stack.ss_sp = memory
        stack.ss_size = size
        stack.ss_flags = 0
        guard sigaltstack(&stack, nil) == 0 else {
            memory.deallocate()
            return false
        }
        alternate = memory
        return true
    }

    private static func installHandlers() -> Bool {
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND
        action.__sigaction_u.__sa_sigaction = gdsHandleCrash
        let signals = [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP]
        var armed = false
        for signal in signals where sigaction(signal, &action, nil) == 0 {
            armed = true
        }
        return armed
    }

    fileprivate static func handle(signal: Int32, context: UnsafeMutableRawPointer?) {
        if OSAtomicCompareAndSwap32(0, 1, entered) == false {
            _exit(128 + signal)
        }
        guard fileDescriptor >= 0 else { return }
        writeSignal(signal)
        let registers = registers(from: context)
        let count = fill(pc: registers.pc, lr: registers.lr, fp: registers.fp, into: frames, capacity: frameLimit, read: readWord)
        for index in 0..<count {
            writeFrame(frames[index])
        }
        _ = fsync(fileDescriptor)
        raise(signal)
    }

    private static func registers(from context: UnsafeMutableRawPointer?) -> (pc: UInt64, lr: UInt64, fp: UInt64) {
        guard let context else { return (0, 0, 0) }
        let machine = context.assumingMemoryBound(to: ucontext_t.self).pointee.uc_mcontext
        guard let machine else { return (0, 0, 0) }
        #if arch(arm64)
        return (machine.pointee.__ss.__pc, machine.pointee.__ss.__lr, machine.pointee.__ss.__fp)
        #elseif arch(x86_64)
        return (machine.pointee.__ss.__rip, 0, machine.pointee.__ss.__rbp)
        #else
        return (0, 0, 0)
        #endif
    }

    static func fill(pc: UInt64, lr: UInt64, fp: UInt64, into out: UnsafeMutablePointer<UInt64>, capacity: Int, read: (UInt64) -> UInt64?) -> Int {
        guard capacity > 0 else { return 0 }
        var count = 0
        func push(_ value: UInt64) {
            guard value > 0x1000, count < capacity else { return }
            if count > 0, out[count - 1] == value { return }
            out[count] = value
            count += 1
        }
        push(pc)
        push(lr)
        var frame = fp
        var steps = 0
        while count < capacity, steps < capacity {
            steps += 1
            if frame < 0x1000 || frame % 8 != 0 { break }
            guard let next = read(frame), let ret = read(frame &+ 8) else { break }
            push(ret)
            if next <= frame { break }
            frame = next
        }
        return count
    }

    private static func readWord(_ address: UInt64) -> UInt64? {
        var value: UInt64 = 0
        var outSize: vm_size_t = 0
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            vm_read_overwrite(
                mach_task_self_,
                vm_address_t(address),
                vm_size_t(MemoryLayout<UInt64>.size),
                vm_address_t(UInt(bitPattern: Int(bitPattern: pointer))),
                &outSize
            )
        }
        guard result == KERN_SUCCESS, outSize == vm_size_t(MemoryLayout<UInt64>.size) else { return nil }
        return value
    }

    private static func writeSignal(_ signal: Int32) {
        var offset = 0
        append(ascii: "S\t", at: &offset)
        appendDecimal(Int(signal), at: &offset)
        append(ascii: "\n", at: &offset)
        flushLine(offset)
    }

    private static func writeFrame(_ pc: UInt64) {
        var offset = 0
        append(ascii: "F\t", at: &offset)
        appendHex(pc, at: &offset)
        append(ascii: "\t", at: &offset)
        if let image = image(containing: pc) {
            appendHex(image.start, at: &offset)
            append(ascii: "\t", at: &offset)
            append(ascii: image.path, at: &offset)
        } else {
            appendHex(0, at: &offset)
            append(ascii: "\t?", at: &offset)
        }
        append(ascii: "\n", at: &offset)
        flushLine(offset)
    }

    private static func append(ascii: UnsafePointer<CChar>, at offset: inout Int) {
        var cursor = ascii
        while cursor.pointee != 0 {
            append(UInt8(bitPattern: cursor.pointee), at: &offset)
            cursor += 1
        }
    }

    private static func append(_ byte: UInt8, at offset: inout Int) {
        guard offset < lineCapacity - 1 else { return }
        line[offset] = byte
        offset += 1
    }

    private static func appendHex(_ value: UInt64, at offset: inout Int) {
        append(UInt8(ascii: "0"), at: &offset)
        append(UInt8(ascii: "x"), at: &offset)
        var shift = 60
        var started = false
        while shift >= 0 {
            let nibble = Int((value >> UInt64(shift)) & 0xf)
            if nibble != 0 || started || shift == 0 {
                started = true
                let digit: UInt8 = nibble < 10
                    ? UInt8(ascii: "0") + UInt8(nibble)
                    : UInt8(ascii: "a") + UInt8(nibble - 10)
                append(digit, at: &offset)
            }
            if shift == 0 { break }
            shift -= 4
        }
    }

    private static func image(containing pc: UInt64) -> Image? {
        guard let images else { return nil }
        for image in images where pc >= image.start && pc < image.end {
            return image
        }
        return nil
    }

    private static func appendDecimal(_ value: Int, at offset: inout Int) {
        var number = value
        if number < 0 {
            append(UInt8(ascii: "-"), at: &offset)
            number = -number
        }
        if number >= 100 {
            append(UInt8(ascii: "0") + UInt8(number / 100), at: &offset)
        }
        if number >= 10 {
            append(UInt8(ascii: "0") + UInt8((number / 10) % 10), at: &offset)
        }
        append(UInt8(ascii: "0") + UInt8(number % 10), at: &offset)
    }

    private static func flushLine(_ count: Int) {
        var sent = 0
        while sent < count {
            let wrote = write(fileDescriptor, line + sent, count - sent)
            if wrote <= 0 { return }
            sent += wrote
        }
    }

    private static func render(_ raw: String) -> String {
        var signal = ""
        var stored: [(pc: UInt64, base: UInt64, path: String)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, parts[0] == "S" {
                signal = parts[1]
            } else if parts.count >= 4, parts[0] == "F", let pc = parseHex(parts[1]), let base = parseHex(parts[2]) {
                stored.append((pc, base, parts[3]))
            }
        }
        var lines: [String] = []
        if !signal.isEmpty { lines.append("signal \(signal)") }
        let symbols = symbolicate(stored)
        for (index, frame) in stored.enumerated() {
            let name = URL(fileURLWithPath: frame.path).lastPathComponent
            let shown = name.isEmpty || name == "?" ? "???" : name
            let offset = frame.base > 0 && frame.pc >= frame.base ? frame.pc - frame.base : frame.pc
            var text = "\(index) \(shown) + 0x\(String(offset, radix: 16))"
            if index < symbols.count, !symbols[index].isEmpty {
                text += " \(symbols[index])"
            }
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    private static func symbolicate(_ frames: [(pc: UInt64, base: UInt64, path: String)]) -> [String] {
        var result = Array(repeating: "", count: frames.count)
        var groups: [String: (base: UInt64, indexes: [Int])] = [:]
        for (index, frame) in frames.enumerated() where frame.base != 0 && frame.path != "?" {
            var group = groups[frame.path] ?? (frame.base, [])
            group.indexes.append(index)
            groups[frame.path] = group
        }
        for (path, group) in groups {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/atos") else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
            let addresses = group.indexes.map { String(format: "0x%llx", frames[$0].pc) }
            process.arguments = ["-o", path, "-l", String(format: "0x%llx", group.base)] + addresses
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { continue }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let symbols = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (offset, index) in group.indexes.enumerated() where offset < symbols.count {
                let symbol = symbols[offset].trimmingCharacters(in: .whitespaces)
                if symbol.isEmpty || symbol.hasPrefix("0x") { continue }
                result[index] = symbol
            }
        }
        return result
    }

    private static func parseHex(_ text: String) -> UInt64? {
        var digits = text
        if digits.hasPrefix("0x") { digits.removeFirst(2) }
        return UInt64(digits, radix: 16)
    }

    private static func flatten(_ node: [String: Any], into lines: inout [String]) {
        let name = node["binaryName"] as? String ?? shortUUID(node["binaryUUID"] as? String)
        let offset = intValue(node["offsetIntoBinaryTextSegment"])
        lines.append("\(name) + \(offset)")
        for child in node["subFrames"] as? [[String: Any]] ?? [] {
            flatten(child, into: &lines)
        }
    }

    private static func shortUUID(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "???" }
        return String(value.prefix(8))
    }

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let value as Int: return value
        case let value as Int64: return Int(value)
        case let value as NSNumber: return value.intValue
        default: return 0
        }
    }
}

private func gdsHandleCrash(_ signal: Int32, _ info: UnsafeMutablePointer<__siginfo>?, _ context: UnsafeMutableRawPointer?) {
    CrashStack.handle(signal: signal, context: context)
}
