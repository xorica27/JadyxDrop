// JadyxDrop — drop NSP games onto a Mac window and send them to Jadyx Portal on an Xbox.
// Speaks the same resumable (TUS-style) protocol as the portal's own web page.
import SwiftUI
import AppKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Portal protocol

struct PortalError: LocalizedError {
    let code: String
    var errorDescription: String? { PortalError.words[code] ?? code }
    static let words: [String: String] = [
        "bad": "Incorrect or expired code. Generate another in Jadyx.",
        "lost": "Connection closed. Reconnect with a new code; confirmed progress is kept.",
        "same": "A different file is pending on the console. Drop that file again to resume, or Discard it.",
        "busy": "Wait for the operation in Jadyx to finish.",
        "exists": "A game with this name already exists on the console.",
        "space": "Not enough free space on the console.",
        "file": "Invalid filename or file. Choose an NSP.",
        "base": "Base games only; updates, DLC and mixed packages are not supported.",
        "nsp": "Invalid NSP structure.",
        "incomplete": "The NSP is incomplete.",
        "keys": "Cannot read its metadata. Check the console keys and the NSP file.",
        "disk": "The console could not write or publish this file.",
        "interrupted": "Transfer interrupted. Drop the file again to resume.",
        "partial": "An upload is pending on the console. Resume or Discard it.",
        "recovery": "Cannot recover the partial file. Discard it first.",
        "unavailable": "Import is currently unavailable in Jadyx.",
        "destination": "Dev storage (D:) is not available. Choose internal storage.",
        "attempts": "Too many attempts. Wait one minute.",
        "version": "Incompatible upload version.",
        "offset": "The console reported an unexpected upload position.",
        "paused": "Paused.",
    ]
}

final class Portal {
    var base: String
    var session = ""
    init(base: String) { self.base = base }

    @discardableResult
    func call(_ method: String, _ path: String, json: [String: Any]? = nil,
              headers: [String: String] = [:], body: Data? = nil,
              timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path.hasPrefix("http") ? path : base + path) else { throw PortalError(code: "interrupted") }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        // The portal refuses requests that do not look like they came from its own page.
        r.setValue(base, forHTTPHeaderField: "Origin")
        r.setValue(base + "/", forHTTPHeaderField: "Referer")
        r.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        r.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        r.setValue("Mozilla/5.0 JadyxDrop", forHTTPHeaderField: "User-Agent")
        r.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        if !session.isEmpty { r.setValue("Bearer " + session, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        var payload = body
        if let json {
            payload = try JSONSerialization.data(withJSONObject: json)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, resp: URLResponse
        do {
            if let payload, method != "GET" {
                (data, resp) = try await URLSession.shared.upload(for: r, from: payload)
            } else {
                (data, resp) = try await URLSession.shared.data(for: r)
            }
        } catch { throw PortalError(code: "interrupted") }
        let http = resp as! HTTPURLResponse
        if http.statusCode == 401 { throw PortalError(code: path == "/api/v1/pair" ? "bad" : "lost") }
        if http.statusCode == 429 { throw PortalError(code: "attempts") }
        if !(200..<300).contains(http.statusCode) {
            let e = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw PortalError(code: e ?? "interrupted")
        }
        return (data, http)
    }

    func pair(_ code: String) async throws {
        session = ""
        let (d, _) = try await call("POST", "/api/v1/pair", json: ["code": code])
        guard let s = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["session"] as? String else {
            throw PortalError(code: "bad")
        }
        session = s
    }

    func status() async throws -> [String: Any] {
        let (d, _) = try await call("GET", "/api/v1/status")
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
}

// MARK: - XCI → NSP

struct ConvertError: LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

/// Repacks an XCI's secure partition (the game's NCAs + CNMT) into an NSP (PFS0). Nothing is decrypted:
/// the NCAs are copied byte for byte, so this needs no keys and keeps the game exactly as dumped.
func convertXCI(_ src: URL, to dst: URL, cancelled: () -> Bool, progress: (Double) -> Void) throws {
    let fh = try FileHandle(forReadingFrom: src); defer { try? fh.close() }
    let size = Int64(try fh.seekToEnd())
    func read(_ off: Int64, _ n: Int) throws -> Data {
        try fh.seek(toOffset: UInt64(off)); return try fh.read(upToCount: n) ?? Data()
    }
    func u32(_ d: Data, _ o: Int) -> UInt32 { d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
    func u64(_ d: Data, _ o: Int) -> UInt64 { d.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } }
    func hfs0(_ off: Int64) throws -> [(name: String, off: Int64, size: Int64)] {
        let h = try read(off, 16)
        guard h.count == 16, h.prefix(4) == Data("HFS0".utf8) else { throw ConvertError("Not a valid XCI (partition table missing).") }
        let n = Int(u32(h, 4)), strSize = Int(u32(h, 8))
        let table = try read(off + 16, 0x40 * n + strSize)
        let strs = table.subdata(in: 0x40 * n..<table.count)
        let dataStart = off + 16 + Int64(0x40 * n + strSize)
        return (0..<n).map { i in
            let e = 0x40 * i
            let nameOff = Int(u32(table, e + 16))
            let nameEnd = strs[nameOff...].firstIndex(of: 0) ?? strs.endIndex
            return (String(decoding: strs[nameOff..<nameEnd], as: UTF8.self), dataStart + Int64(u64(table, e)), Int64(u64(table, e + 8)))
        }
    }
    let head = try read(0x100, 0x100)
    guard head.prefix(4) == Data("HEAD".utf8) else { throw ConvertError("Not an XCI file (no HEAD header).") }
    guard let secure = try hfs0(Int64(u64(head, 0x30))).first(where: { $0.name == "secure" }) else {
        throw ConvertError("This XCI has no secure (game) partition.")
    }
    let files = try hfs0(secure.off)
    guard files.contains(where: { $0.name.hasSuffix(".cnmt.nca") }) else { throw ConvertError("No game metadata (.cnmt.nca) found in this XCI.") }
    for f in files where f.off + f.size > size { throw ConvertError("\(f.name) runs past the end of the XCI — the dump is incomplete.") }

    var names = Data(); var entries = Data(); var dataOff: UInt64 = 0
    func put<T: FixedWidthInteger>(_ v: T, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    for f in files {
        put(dataOff, &entries); put(UInt64(f.size), &entries); put(UInt32(names.count), &entries); put(UInt32(0), &entries)
        names.append(Data(f.name.utf8)); names.append(0)
        dataOff += UInt64(f.size)
    }
    let headLen = 16 + entries.count + names.count
    names.append(Data(count: (0x20 - headLen % 0x20) % 0x20))
    var header = Data("PFS0".utf8)
    put(UInt32(files.count), &header); put(UInt32(names.count), &header); put(UInt32(0), &header)
    header += entries + names

    FileManager.default.createFile(atPath: dst.path, contents: nil)
    let out = try FileHandle(forWritingTo: dst)
    var ok = false
    defer { try? out.close(); if !ok { try? FileManager.default.removeItem(at: dst) } }
    try out.write(contentsOf: header)
    let total = Double(files.reduce(0) { $0 + $1.size }); var copied: Int64 = 0
    for f in files {
        try fh.seek(toOffset: UInt64(f.off)); var left = f.size
        while left > 0 {
            if cancelled() { throw ConvertError("Paused.") }
            let chunk = try fh.read(upToCount: Int(min(left, 8 << 20))) ?? Data()
            guard !chunk.isEmpty else { throw ConvertError("Unexpected end of the XCI.") }
            try out.write(contentsOf: chunk); left -= Int64(chunk.count); copied += Int64(chunk.count)
            progress(Double(copied) / max(total, 1))
        }
    }
    ok = true
}

/// Same resume fingerprint as the portal page: sha256(JSON [name,size,mtimeMs] + first 64 KiB + last 64 KiB).
func fingerprint(_ url: URL, name: String, size: Int64) throws -> String {
    let mtime = (try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
    let ms = Int64((mtime.timeIntervalSince1970 * 1000).rounded(.down))
    var ident = try JSONSerialization.data(withJSONObject: [name, size, ms], options: [.withoutEscapingSlashes])
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    ident.append(try h.read(upToCount: 65536) ?? Data())
    try h.seek(toOffset: UInt64(max(0, size - 65536)))
    ident.append(try h.readToEnd() ?? Data())
    return SHA256.hash(data: ident).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Model

struct Item: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    var state = "Queued"
    var progress = 0.0
    var speed = ""
    var done = false
    var failed = false
    var paused = false
    var nspURL: URL? = nil      // converted NSP for an XCI
    var tempNSP = false         // delete the converted NSP once installed
    var name: String { url.lastPathComponent }
    var isXCI: Bool { url.pathExtension.lowercased() == "xci" }
}

@MainActor
final class Model: ObservableObject {
    @AppStorage("host") var host = ""
    @Published var code = ""
    @Published var connected = false
    @Published var busyConnecting = false
    @Published var message = "Start the server in Jadyx (Settings › File manager › Network connection), then type the 4-digit code."
    @Published var destination = "internal"
    @Published var items: [Item] = []
    @Published var running = false
    @Published var pendingOnConsole: String? = nil
    private var stopped = false
    private var portal = Portal(base: "")
    private var keepAlive: Task<Void, Never>?
    private let chunk = 16 * 1_048_576
    @AppStorage("keepNSP") var keepNSP = false
    static let accepted: Set<String> = ["nsp", "xci"]

    /// "192.168.1.20" → "http://192.168.1.20:8080" (Jadyx Portal's default port).
    var baseURL: String {
        var h = host.trimmingCharacters(in: .whitespaces)
        if !h.hasPrefix("http") { h = "http://" + h }
        if let u = URL(string: h), u.port == nil, let hostPart = u.host { h = "\(u.scheme ?? "http")://\(hostPart):8080" }
        return h
    }

    func connect() {
        guard code.count == 4, !busyConnecting else { return }
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { message = "Enter your Xbox's IP address first (shown in Jadyx Portal's screen)."; return }
        busyConnecting = true
        portal = Portal(base: baseURL)
        let c = code
        Task {
            defer { busyConnecting = false }
            do {
                try await portal.pair(c)
                code = ""
                connected = true
                message = "Connected. Drop .nsp or .xci files to send them."
                try await refreshPending()
                startKeepAlive()
                if items.contains(where: { !$0.done && !$0.failed }) { start() }
            } catch {
                code = ""
                message = error.localizedDescription
            }
        }
    }

    func disconnect(_ why: String) {
        connected = false
        keepAlive?.cancel()
        portal.session = ""
        message = why
    }

    private func startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled || running { continue }
                do { try await refreshPending() } catch let e as PortalError where e.code == "lost" {
                    disconnect(e.localizedDescription)
                } catch {}
            }
        }
    }

    private func refreshPending() async throws {
        let t = try await portal.status()["transfer"] as? [String: Any] ?? [:]
        let phase = t["phase"] as? String ?? ""
        if let id = t["id"] as? String, !id.isEmpty, phase != "complete", !running {
            pendingOnConsole = "\(t["name"] as? String ?? "file") (\(phase))"
        } else if !running { pendingOnConsole = nil }
    }

    func add(_ urls: [URL]) {
        for u in urls where Model.accepted.contains(u.pathExtension.lowercased()) {
            if items.contains(where: { $0.url == u && !$0.done && !$0.failed }) { continue }
            let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            var it = Item(url: u, size: size)
            if !connected { it.state = it.isXCI ? "XCI · will convert to NSP · waiting for a portal code" : "Waiting for a portal code" }
            items.append(it)
        }
        let rejected = urls.filter { !Model.accepted.contains($0.pathExtension.lowercased()) }
        if !rejected.isEmpty { message = "Skipped \(rejected.count) file(s) that aren't .nsp or .xci." }
        start()
    }

    func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = Model.accepted.map { UTType(filenameExtension: $0) ?? .data }
        if p.runModal() == .OK { add(p.urls) }
    }

    func retryFailed() {
        for i in items.indices where items[i].failed || items[i].paused {
            items[i].failed = false; items[i].paused = false; items[i].state = "Queued"; items[i].progress = 0
        }
        start()
    }

    func clearFinished() { items.removeAll { $0.done || $0.failed } }

    private func eligible(_ it: Item) -> Bool { !it.done && !it.failed && !it.paused && connected }
    var hasWaiting: Bool { items.contains { !$0.done && !$0.failed } }

    func resume() {
        for i in items.indices where items[i].paused { items[i].paused = false; items[i].state = "Queued" }
        start()
    }

    func start() {
        guard !running else { return }
        running = true; stopped = false
        Task {
            defer { running = false }
            while !stopped, let i = items.firstIndex(where: eligible) {
                do {
                    if items[i].isXCI && items[i].nspURL == nil { try await convert(i) }
                    try await send(i)
                    items[i].state = items[i].isXCI
                        ? (items[i].tempNSP ? "Converted and installed in library" : "Installed in library · NSP saved next to the XCI")
                        : "Installed in library"
                    if items[i].tempNSP, let n = items[i].nspURL { try? FileManager.default.removeItem(at: n); items[i].nspURL = nil }
                    items[i].done = true; items[i].progress = 1; items[i].speed = ""
                } catch let e as PortalError {
                    items[i].speed = ""
                    if e.code == "lost" { items[i].state = "Waiting to reconnect"; disconnect(e.localizedDescription); continue }
                    if e.code == "paused" { items[i].paused = true; items[i].state = "Paused"; break }
                    items[i].failed = true; items[i].state = e.localizedDescription
                } catch {
                    items[i].speed = ""
                    if stopped { items[i].paused = true; items[i].state = "Paused"; break }
                    items[i].failed = true; items[i].state = error.localizedDescription
                }
            }
            for i in items.indices where !items[i].done && !items[i].failed && !items[i].paused && !connected {
                items[i].state = "Waiting for a portal code"
            }
            if !items.isEmpty && items.allSatisfy({ $0.done }) { message = "All uploads finished." }
            if connected { try? await refreshPending() }
        }
    }

    /// XCI → NSP, either next to the XCI (when "Keep converted NSP" is on and the folder is writable) or in Caches.
    private func convert(_ i: Int) async throws {
        let src = items[i].url
        let nspName = src.deletingPathExtension().lastPathComponent + ".nsp"
        var dst = src.deletingLastPathComponent().appendingPathComponent(nspName)
        var temp = !keepNSP
        if keepNSP, FileManager.default.fileExists(atPath: dst.path) {
            items[i].nspURL = dst; items[i].tempNSP = false; return      // already converted earlier
        }
        if temp || !FileManager.default.isWritableFile(atPath: src.deletingLastPathComponent().path) {
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("JadyxDrop", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            dst = cache.appendingPathComponent(nspName); temp = true
        }
        items[i].state = "Converting XCI → NSP"
        let id = items[i].id
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try convertXCI(src, to: dst, cancelled: { self?.isStopped ?? true }) { frac in
                Task { @MainActor in
                    guard let self, let k = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[k].progress = frac
                    self.items[k].state = "Converting XCI → NSP · \(Int(frac * 100))%"
                }
            }
        }.value
        items[i].nspURL = dst; items[i].tempNSP = temp; items[i].progress = 0; items[i].speed = ""
    }

    nonisolated var isStopped: Bool { MainActor.assumeIsolated { stopped } }

    func stop() {
        stopped = true
        guard connected else { return }
        Task {
            if let id = (try? await portal.status())?["transfer"].flatMap({ ($0 as? [String: Any])?["id"] as? String }), !id.isEmpty {
                _ = try? await portal.call("POST", "/api/v1/uploads/\(id)/pause")
            }
        }
    }

    func discardPending() {
        Task {
            do {
                guard let t = try await portal.status()["transfer"] as? [String: Any], let id = t["id"] as? String, !id.isEmpty else { return }
                for attempt in 0..<15 {
                    do { try await portal.call("DELETE", "/api/v1/uploads/\(id)"); break }
                    catch let e as PortalError where e.code == "busy" && attempt < 14 { try await Task.sleep(nanoseconds: 100_000_000) }
                }
                pendingOnConsole = nil
                message = "Discarded the partial upload on the console."
            } catch { message = error.localizedDescription }
        }
    }

    private func send(_ i: Int) async throws {
        let url = items[i].nspURL ?? items[i].url, name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? items[i].size
        items[i].state = "Preparing"
        let sig = try fingerprint(url, name: name, size: size)
        var t = try await portal.status()["transfer"] as? [String: Any] ?? [:]
        var id = t["id"] as? String ?? ""
        if !id.isEmpty, (t["phase"] as? String) != "complete" {
            guard t["fingerprint"] as? String == sig, (t["length"] as? NSNumber)?.int64Value == size else { throw PortalError(code: "same") }
        } else {
            let meta = ["filename": name, "fingerprint": sig, "destination": destination]
                .map { "\($0.key) \(Data($0.value.utf8).base64EncodedString())" }.joined(separator: ",")
            let (_, r) = try await portal.call("POST", "/api/v1/uploads", headers: ["Upload-Length": String(size), "Upload-Metadata": meta])
            id = (r.value(forHTTPHeaderField: "Location") ?? "").split(separator: "/").last.map(String.init) ?? ""
        }
        let path = "/api/v1/uploads/\(id)"
        func head() async throws -> Int64 {
            let (_, r) = try await portal.call("HEAD", path)
            return Int64(r.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? 0
        }
        var offset = try await head(), attempts = 0
        let fh = try FileHandle(forReadingFrom: url); defer { try? fh.close() }
        var window: [(Double, Double)] = []
        items[i].state = "Uploading"
        while offset < size {
            if stopped { throw PortalError(code: "paused") }
            try fh.seek(toOffset: UInt64(offset))
            let blob = try fh.read(upToCount: chunk) ?? Data()
            let t0 = Date(), before = offset
            do {
                let (_, r) = try await portal.call("PATCH", path, headers: [
                    "Content-Type": "application/offset+octet-stream", "Upload-Offset": String(offset)], body: blob, timeout: 120)
                guard let next = Int64(r.value(forHTTPHeaderField: "Upload-Offset") ?? ""), next > before, next <= size else {
                    throw PortalError(code: "offset")
                }
                offset = next; attempts = 0
                window.append((Double(offset - before), max(0.001, Date().timeIntervalSince(t0))))
                if window.count > 8 { window.removeFirst() }
                let bps = window.map(\.0).reduce(0, +) / window.map(\.1).reduce(0, +)
                let eta = Double(size - offset) / max(bps, 1)
                items[i].progress = Double(offset) / Double(max(size, 1))
                items[i].speed = String(format: "%.1f MiB/s · %@ left", bps / 1_048_576, formatETA(eta))
            } catch let e as PortalError where ["interrupted", "offset"].contains(e.code) && attempts < 5 && !stopped {
                attempts += 1
                try await Task.sleep(nanoseconds: UInt64(min(3000, 250 * (1 << attempts))) * 1_000_000)
                offset = try await head()
            }
        }
        try await portal.call("POST", path + "/finish")
        items[i].speed = ""
        while true {
            try await Task.sleep(nanoseconds: 500_000_000)
            t = try await portal.status()["transfer"] as? [String: Any] ?? [:]
            let phase = t["phase"] as? String ?? ""
            if let e = t["error"] as? String, !e.isEmpty { throw PortalError(code: e) }
            switch phase {
            case "complete": return
            case "paused": throw PortalError(code: "paused")
            case "validating": items[i].state = "Validating NSP on console"
            case "publishing": items[i].state = "Adding to library"
            default: items[i].state = "Waiting for console"
            }
        }
    }
}

func formatETA(_ s: Double) -> String {
    guard s.isFinite else { return "—" }
    let t = Int(s.rounded(.up))
    return t >= 3600 ? "\(t / 3600) h \(t % 3600 / 60) min" : t >= 60 ? "\(t / 60) min \(t % 60) s" : "\(t) s"
}

func fmtSize(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .binary) }

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var m: Model
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(m.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 9, height: 9)
                Text(m.connected ? "Connected to Jadyx" : "Not connected").font(.headline)
                Spacer()
                TextField("Xbox IP, e.g. 192.168.1.20", text: $m.host)
                    .textFieldStyle(.roundedBorder).frame(width: 190).disabled(m.connected)
            }
            if !m.connected {
                HStack {
                    TextField("Code", text: $m.code)
                        .textFieldStyle(.roundedBorder).font(.system(.title2, design: .monospaced)).frame(width: 110)
                        .onChange(of: m.code) { _, v in
                            let d = String(v.filter(\.isNumber).prefix(4))
                            if d != v { m.code = d }
                            if d.count == 4 { m.connect() }
                        }
                        .onSubmit { m.connect() }
                    Button(m.busyConnecting ? "Connecting…" : "Connect") { m.connect() }
                        .disabled(m.code.count != 4 || m.busyConnecting || m.host.isEmpty)
                }
            }
            Picker("Install to", selection: $m.destination) {
                Text("Internal storage").tag("internal")
                Text("Dev storage (D:)").tag("developer")
            }.pickerStyle(.segmented).disabled(m.running)
            Toggle("Keep converted .nsp next to the .xci (otherwise it's deleted after installing)", isOn: $m.keepNSP)
                .font(.callout)

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .background(RoundedRectangle(cornerRadius: 14).fill(targeted ? Color.accentColor.opacity(0.08) : Color.clear))
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 30))
                    Text("Drop .nsp or .xci games here").font(.title3)
                    Text(".xci files are converted to .nsp on this Mac, then installed through Jadyx Portal")
                        .font(.caption)
                    Button("Choose files…") { m.choose() }.buttonStyle(.link)
                }.foregroundStyle(.secondary)
            }
            .frame(height: 140)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in m.add([url]) } }
                    }
                }
                return true
            }

            if let pending = m.pendingOnConsole {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Partial upload on console: \(pending)").font(.callout)
                    Spacer()
                    Button("Discard") { m.discardPending() }
                }
            }

            List(m.items) { it in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: it.done ? "checkmark.circle.fill" : it.failed ? "xmark.octagon.fill" : "gamecontroller")
                            .foregroundStyle(it.done ? .green : it.failed ? .red : .secondary)
                        Text(it.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(fmtSize(it.size)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if !it.done && !it.failed && it.progress > 0 { ProgressView(value: it.progress) }
                    Text(it.speed.isEmpty ? it.state : "\(it.state) · \(Int(it.progress * 100))% · \(it.speed)")
                        .font(.caption).foregroundStyle(it.failed ? .red : .secondary)
                }.padding(.vertical, 3)
            }
            .frame(minHeight: 160)

            HStack {
                Text(m.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if m.items.contains(where: \.failed) { Button("Retry failed") { m.retryFailed() }.disabled(m.running) }
                if m.items.contains(where: { $0.done || $0.failed }) { Button("Clear finished") { m.clearFinished() }.disabled(m.running) }
                if m.running { Button("Pause") { m.stop() } }
                else if m.items.contains(where: \.paused) { Button("Resume") { m.resume() } }
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 520)
    }
}

/// Files dropped on the Dock icon or opened with "Open With → JadyxDrop".
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pending: [URL] = []
    static var sink: (([URL]) -> Void)?
    func application(_ application: NSApplication, open urls: [URL]) {
        if let sink = Self.sink { sink(urls) } else { Self.pending += urls }
    }
}

@main
struct JadyxDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()
    var body: some Scene {
        WindowGroup("JadyxDrop") {
            ContentView().environmentObject(model).onAppear {
                AppDelegate.sink = { urls in Task { @MainActor in model.add(urls) } }
                if !AppDelegate.pending.isEmpty { model.add(AppDelegate.pending); AppDelegate.pending = [] }
            }
        }
            .windowResizability(.contentMinSize)
    }
}
