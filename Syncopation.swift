// Syncopation — Community Edition.
//
// A native macOS app that copies music, books, or any files onto an SD card,
// a folder, or an iPod. It only ever ADDS: nothing is deleted by syncing.
// Clearing a destination is a separate, deliberate action — the Erase button.
//
// Copyright (C) 2026 Eddie Hajek
// Licensed under the GNU General Public License v3.0 — see the LICENSE file.

import SwiftUI
import AppKit

let junkNames: Set<String> = [".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd"]

let musicExtensions: Set<String> = [
    "mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif",
    "ogg", "opus", "wma", "ape", "dsf", "dff",
]
let bookExtensions: Set<String> = ["epub", "pdf"]

enum SyncMode: String, CaseIterable, Identifiable {
    case music, books, all, ipod
    var id: String { rawValue }

    var label: String {
        switch self {
        case .music: return "Music"
        case .books: return "ePUB/PDF"
        case .all: return "All Files"
        case .ipod: return "iPod"
        }
    }

    var details: String {
        switch self {
        case .music:
            return "Copies audio files only — MP3, M4A/M4B, AAC, FLAC, WAV, AIFF, OGG, "
                 + "Opus, WMA, APE, DSF, DFF — keeping your folder structure."
        case .books:
            return "Copies books and documents only — ePUB and PDF — keeping your "
                 + "folder structure."
        case .all:
            return "Copies everything in the source folder, no filtering."
        case .ipod:
            return "Loads music onto an iPod in disk mode. FLAC is converted to ALAC "
                 + "(Apple Lossless); MP3, AAC and ALAC copy as-is. Tracks are added to "
                 + "the iPod's library so they play as soon as you eject."
        }
    }

    /// nil means no filtering.
    var allowedExtensions: Set<String>? {
        switch self {
        case .music, .ipod: return musicExtensions
        case .books: return bookExtensions
        case .all: return nil
        }
    }
}

struct SourceFile {
    let url: URL
    let relativePath: String
    let size: Int64
}

// MARK: - Finding and identifying iPods

struct IPodDevice: Identifiable, Equatable {
    let volumePath: String
    let name: String
    let family: String
    let serial: String?
    let dbVersion: Int?
    let needsHashedDB: Bool
    let isShuffle: Bool
    let firewireGUID: String?
    let capacity: Int64
    let free: Int64

    var id: String { volumePath }

    /// Tint for the device icon, taken from the model's own colour.
    var shellColor: Color {
        let f = family.lowercased()
        if f.contains("black") { return .black }
        if f.contains("silver") || f.contains("stainless") { return .gray }
        if f.contains("blue") { return .blue }
        if f.contains("green") { return .green }
        if f.contains("pink") { return .pink }
        if f.contains("purple") { return .purple }
        if f.contains("orange") { return .orange }
        if f.contains("red") { return .red }
        if f.contains("yellow") || f.contains("gold") { return .yellow }
        return .secondary
    }

    var unsupportedReason: String? {
        if isShuffle {
            return "the iPod shuffle uses a different library format, which this app doesn't write"
        }
        if let v = dbVersion, v >= 4 {
            return "this iPod uses a library format this app doesn't write"
        }
        return nil
    }

    var summary: String {
        let cap = ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)
        let fr = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if let reason = unsupportedReason {
            return "Not supported: \(family) “\(name)” — \(reason)."
        }
        var s = "Found: \(family) “\(name)” · \(cap), \(fr) free"
        if let serial { s += " · SN \(serial)" }
        return s
    }
}

private func sysInfoValue(_ key: String, in text: String, tag: String) -> String? {
    guard let r = text.range(of: "<key>\(key)</key>") else { return nil }
    let after = text[r.upperBound...].prefix(200)
    guard let o = after.range(of: "<\(tag)>"), let c = after.range(of: "</\(tag)>") else { return nil }
    return String(after[o.upperBound..<c.lowerBound])
}

private func identify(serial: String?, modelNumber: String) -> IPodModelInfo? {
    if let serial, serial.count >= 3,
       let hit = ipodSerialModels[String(serial.suffix(3)).uppercased()] { return hit }
    var num = modelNumber.uppercased()
    if num.hasPrefix("X") { num = String(num.dropFirst()) }
    if num.hasPrefix("M") { num = String(num.dropFirst()) }
    if num.count >= 4, let hit = ipodNumberModels[String(num.prefix(4))] { return hit }
    return nil
}

/// An iPod in disk mode is a volume with iPod_Control/Device on it.
func detectIPods() -> [IPodDevice] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                  .volumeAvailableCapacityKey]
    let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                    options: [.skipHiddenVolumes]) ?? []
    var found: [IPodDevice] = []
    for vol in urls where vol.path.hasPrefix("/Volumes/") {
        let device = vol.appendingPathComponent("iPod_Control/Device")
        let sysInfo = device.appendingPathComponent("SysInfo").path
        let sysInfoExtended = device.appendingPathComponent("SysInfoExtended").path
        guard fm.fileExists(atPath: sysInfo) || fm.fileExists(atPath: sysInfoExtended)
        else { continue }

        var model = "", guid: String? = nil, serial: String? = nil
        var dbVersion: Int? = nil

        // Plain key: value text, written by the iPod itself. Often empty.
        if let text = try? String(contentsOfFile: sysInfo, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "ModelNumStr" { model = value }
                if key.lowercased() == "firewireguid" { guid = value }
                if key == "pszSerialNumber" { serial = value }
            }
        }
        // XML written by iTunes/Music — not always valid XML, so scanned as text.
        if let text = try? String(contentsOfFile: sysInfoExtended, encoding: .utf8) {
            if model.isEmpty { model = sysInfoValue("ModelNumStr", in: text, tag: "string") ?? "" }
            if guid == nil { guid = sysInfoValue("FireWireGUID", in: text, tag: "string") }
            serial = sysInfoValue("SerialNumber", in: text, tag: "string") ?? serial
            dbVersion = sysInfoValue("DBVersion", in: text, tag: "integer").flatMap(Int.init)
        }
        if model.hasPrefix("x") { model = String(model.dropFirst()) }

        let hit = identify(serial: serial, modelNumber: model)
        let values = try? vol.resourceValues(forKeys: Set(keys))
        found.append(IPodDevice(
            volumePath: vol.path,
            name: values?.volumeName ?? vol.lastPathComponent,
            family: hit?.display ?? "iPod",
            serial: serial,
            dbVersion: dbVersion,
            // DBVersion decides: 3 and up need the checksummed library. Without
            // the key, only 2007-and-later devices have SysInfoExtended at all.
            needsHashedDB: dbVersion.map { $0 >= 3 } ?? fm.fileExists(atPath: sysInfoExtended),
            isShuffle: hit?.isShuffle ?? false,
            firewireGUID: guid,
            capacity: Int64(values?.volumeTotalCapacity ?? 0),
            free: Int64(values?.volumeAvailableCapacity ?? 0)))
    }
    return found.sorted { $0.name < $1.name }
}

// MARK: - Model

final class SyncModel: ObservableObject {
    @Published var sourcePath: String
    @Published var destPath: String
    @Published var volumes: [String] = []
    @Published var ipods: [IPodDevice] = []
    @Published var selectedIPod: IPodDevice?
    @Published var logText = ""
    @Published var status = "Ready."
    @Published var running = false
    @Published var done: Double = 0
    @Published var total: Double = 0
    @Published var mode: SyncMode { didSet {
        defaults.set(mode.rawValue, forKey: "syncMode")
        if mode == .ipod { refreshIPods() }
    } }

    var cancelled = false
    private let defaults = UserDefaults.standard

    init() {
        sourcePath = defaults.string(forKey: "source") ?? ""
        destPath = defaults.string(forKey: "destination") ?? ""
        mode = SyncMode(rawValue: defaults.string(forKey: "syncMode") ?? "") ?? .music
        refreshVolumes()
        refreshIPods()
    }

    func refreshVolumes() {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.map(\.path).filter { $0.hasPrefix("/Volumes/") }.sorted()
    }

    func refreshIPods() {
        ipods = detectIPods()
        if let current = selectedIPod,
           let match = ipods.first(where: { $0.volumePath == current.volumePath }) {
            selectedIPod = match
        } else if let saved = defaults.string(forKey: "ipodVolume"),
                  let match = ipods.first(where: { $0.volumePath == saved }) {
            selectedIPod = match
        } else {
            selectedIPod = ipods.count == 1 ? ipods.first : nil
        }
    }

    func selectIPod(_ pod: IPodDevice) {
        selectedIPod = pod
        defaults.set(pod.volumePath, forKey: "ipodVolume")
    }

    func chooseFolder(message: String, initial: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if !initial.isEmpty { panel.directoryURL = URL(fileURLWithPath: initial) }
        if panel.runModal() == .OK, let url = panel.url { completion(url.path) }
    }

    func cancel() {
        cancelled = true
        status = "Stopping…"
    }

    // MARK: Eject

    private var ejectTargetPath: String {
        mode == .ipod ? (selectedIPod?.volumePath ?? "")
                      : destPath.trimmingCharacters(in: .whitespaces)
    }

    var destIsEjectable: Bool { ejectTargetPath.hasPrefix("/Volumes/") }

    func eject() {
        let path = ejectTargetPath
        guard path.hasPrefix("/Volumes/") else {
            alert("The destination isn't a removable disk, so there's nothing to eject.")
            return
        }
        let url = URL(fileURLWithPath: path)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? url
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            status = "Ejected \(volume.lastPathComponent) — safe to unplug."
            refreshVolumes()
            refreshIPods()
        } catch {
            alert("Could not eject \(volume.lastPathComponent): \(error.localizedDescription)\n\n"
                + "Make sure no other app is using it.")
        }
    }

    // MARK: Worker plumbing

    func post(_ update: @escaping () -> Void) { DispatchQueue.main.async(execute: update) }
    func log(_ line: String) { post { self.logText += line + "\n" } }

    func finish(_ summary: String) {
        post {
            self.status = summary
            self.logText += summary + "\n"
            self.running = false
            self.done = 0
            self.total = 0
        }
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Syncopation"
        a.informativeText = text
        a.runModal()
    }

    private func scan(_ rootURL: URL, allowed: Set<String>?) -> [SourceFile] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var files: [SourceFile] = []
        let basePath = rootURL.standardizedFileURL.path
        guard let e = fm.enumerator(at: rootURL, includingPropertiesForKeys: Array(keys),
                                    options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in e {
            if cancelled { return files }
            let name = url.lastPathComponent
            if junkNames.contains(name) || name.hasPrefix("._") { continue }
            guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true
            else { continue }
            if let allowed, !allowed.contains(url.pathExtension.lowercased()) { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(basePath + "/") else { continue }
            files.append(SourceFile(url: url,
                                    relativePath: String(full.dropFirst(basePath.count + 1)),
                                    size: Int64(v.fileSize ?? 0)))
        }
        return files
    }

    // MARK: - Sync (adds only)

    func start(dryRun: Bool) {
        if mode == .ipod { startIPod(dryRun: dryRun); return }
        let fm = FileManager.default
        let src = sourcePath.trimmingCharacters(in: .whitespaces)
        let dst = destPath.trimmingCharacters(in: .whitespaces)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else {
            alert("Please choose a valid source folder."); return
        }
        guard fm.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue else {
            alert("Please choose a valid destination — is the card or drive plugged in?"); return
        }
        let realSrc = URL(fileURLWithPath: src).resolvingSymlinksInPath().path
        let realDst = URL(fileURLWithPath: dst).resolvingSymlinksInPath().path
        guard realDst != realSrc, !realDst.hasPrefix(realSrc + "/"), !realSrc.hasPrefix(realDst + "/")
        else {
            alert("Source and destination can't be the same folder, or inside each other."); return
        }
        defaults.set(src, forKey: "source")
        defaults.set(dst, forKey: "destination")
        beginRun(dryRun ? "Checking…" : "Scanning…")
        let allowed = mode.allowedExtensions
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            runFolder(src: src, dst: dst, dryRun: dryRun, allowed: allowed)
        }
    }

    private func beginRun(_ status: String) {
        logText = ""
        done = 0
        total = 0
        cancelled = false
        running = true
        self.status = status
    }

    private func runFolder(src: String, dst: String, dryRun: Bool, allowed: Set<String>?) {
        let fm = FileManager.default
        let files = scan(URL(fileURLWithPath: src), allowed: allowed)
        if cancelled { finish("Stopped."); return }
        log("Found \(files.count) matching files in the source folder.")

        var todo: [SourceFile] = []
        var skipped = 0
        for f in files {
            if cancelled { finish("Stopped."); return }
            let destFile = dst + "/" + f.relativePath
            if let attrs = try? fm.attributesOfItem(atPath: destFile),
               let size = attrs[.size] as? Int64, size == f.size {
                skipped += 1
            } else {
                todo.append(f)
            }
        }
        let needed = todo.reduce(Int64(0)) { $0 + $1.size }
        let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        log("To copy: \(todo.count) files (\(neededStr)). Already there: \(skipped).")

        if dryRun {
            for f in todo { log("WOULD COPY  \(f.relativePath)") }
            finish("Check done — \(todo.count) files (\(neededStr)) would be copied.")
            return
        }
        var free = Int64.max
        if let attrs = try? fm.attributesOfFileSystem(forPath: dst),
           let f = attrs[.systemFreeSize] as? Int64 { free = f }
        if needed > free {
            finish("Not enough room: \(neededStr) to copy, only "
                 + "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free. "
                 + "Nothing was copied.")
            return
        }

        post { self.total = Double(todo.count) }
        var copied = 0, errors = 0
        for (i, f) in todo.enumerated() {
            if cancelled { finish("Stopped — \(copied) copied."); return }
            let destURL = URL(fileURLWithPath: dst).appendingPathComponent(f.relativePath)
            do {
                try fm.createDirectory(at: destURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                try fm.copyItem(at: f.url, to: destURL)
                copied += 1
                log("COPIED  \(f.relativePath)")
            } catch {
                errors += 1
                log("ERROR   \(f.relativePath): \(error.localizedDescription)")
            }
            let n = Double(i + 1)
            post { self.done = n; self.status = "Copying… \(Int(n))/\(todo.count)" }
        }
        var summary = "Done — \(copied) copied, \(skipped) already there"
        if errors > 0 { summary += ", \(errors) errors" }
        finish(summary + ".")
    }

    // MARK: - Sync to an iPod (adds only)

    private struct Manifest: Codable {
        var version = 1
        var entries: [String: Int64] = [:]   // source path → size
    }

    private func manifestPath(volume: String) -> String {
        volume + "/iPod_Control/Syncopation/manifest.json"
    }

    private func loadManifest(volume: String) -> Manifest {
        guard let d = FileManager.default.contents(atPath: manifestPath(volume: volume)),
              let m = try? JSONDecoder().decode(Manifest.self, from: d) else { return Manifest() }
        return m
    }

    private func saveManifest(_ m: Manifest, volume: String) {
        let path = manifestPath(volume: volume)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: URL(fileURLWithPath: path)) }
    }

    private func startIPod(dryRun: Bool) {
        let fm = FileManager.default
        let src = sourcePath.trimmingCharacters(in: .whitespaces)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else {
            alert("Please choose a valid source folder."); return
        }
        guard let ipod = selectedIPod else {
            alert("Select an iPod first — connect it in disk mode, then click Refresh."); return
        }
        guard fm.fileExists(atPath: ipod.volumePath + "/iPod_Control") else {
            refreshIPods()
            alert("“\(ipod.name)” doesn't seem to be plugged in any more."); return
        }
        if let reason = ipod.unsupportedReason {
            alert("Can't sync to \(ipod.name): \(reason)."); return
        }
        if ipod.needsHashedDB, ipod.firewireGUID == nil {
            alert("\(ipod.name) needs a checksummed library, but its device ID couldn't be read. "
                + "Sync it once with iTunes or Music, then try again."); return
        }
        defaults.set(src, forKey: "source")
        beginRun(dryRun ? "Checking…" : "Scanning…")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            runIPod(src: src, ipod: ipod, dryRun: dryRun)
        }
    }

    private func runIPod(src: String, ipod: IPodDevice, dryRun: Bool) {
        let fm = FileManager.default
        log("Found iPod: “\(ipod.name)” — \(ipod.family)")
        log("Library: \(ipod.needsHashedDB ? "checksummed" : "standard")")

        let dbPath = ipod.volumePath + "/iPod_Control/iTunes/iTunesDB"
        var db: IPodDatabase
        var freshDB = false
        if fm.fileExists(atPath: dbPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: dbPath)),
                  let parsed = try? ITunesDBParser.parse(data) else {
                finish("Could not read the iPod's library. Nothing was changed."); return
            }
            db = parsed
            log("Existing library: \(db.tracks.count) tracks — they're kept.")
        } else {
            db = IPodDatabase()
            freshDB = true
            log("No library yet — a new one will be created.")
        }
        reclaimInterruptedCopies(ipod: ipod, db: db)
        if db.masterPlaylistIndex == nil {
            var mpl = IPodPlaylist()
            mpl.isMaster = true
            mpl.name = ipod.name
            db.playlists.insert(mpl, at: 0)
        }

        var manifest = loadManifest(volume: ipod.volumePath)
        var known = Set(db.tracks.map { tagKey(title: $0.title, artist: $0.artist, album: $0.album) })
        let playsALAC = iPodPlaysALAC(volume: ipod.volumePath, family: ipod.family)
        if !playsALAC {
            log("This iPod is too old for Apple Lossless, so FLAC files are skipped — "
                + "MP3 and AAC copy as normal.")
        }

        let files = scan(URL(fileURLWithPath: src), allowed: musicExtensions)
        if cancelled { finish("Stopped."); return }
        log("Found \(files.count) music files in the source folder.")

        var todo: [(SourceFile, AudioMetadata, Bool)] = []
        var alreadySynced = 0, alreadyThere = 0, unplayable = 0
        for f in files {
            if cancelled { finish("Stopped."); return }
            let ext = (f.relativePath as NSString).pathExtension.lowercased()
            let convert: Bool
            if ipodConvertExtensions.contains(ext) {
                guard playsALAC else { unplayable += 1; continue }
                convert = true
            } else if ipodDirectExtensions.contains(ext) {
                convert = false
            } else { unplayable += 1; continue }

            if manifest.entries[f.relativePath] == f.size { alreadySynced += 1; continue }
            let meta = MetadataReader.read(url: f.url)
            if known.contains(tagKey(title: meta.title, artist: meta.artist, album: meta.album)) {
                alreadyThere += 1; continue
            }
            todo.append((f, meta, convert))
        }
        let needed = todo.reduce(Int64(0)) { $0 + $1.0.size }
        let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        var free = Int64.max
        if let attrs = try? fm.attributesOfFileSystem(forPath: ipod.volumePath),
           let f = attrs[.systemFreeSize] as? Int64 { free = f }
        let freeStr = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        log("To add: \(todo.count) tracks (about \(neededStr)). \(freeStr) free on “\(ipod.name)”.")
        log("Skipped: \(alreadySynced) synced before, \(alreadyThere) already on the iPod, "
            + "\(unplayable) this iPod can't play.")
        log("Syncing only adds — nothing is ever deleted from the iPod.")

        if dryRun {
            for t in todo { log("WOULD \(t.2 ? "CONVERT" : "COPY   ")  \(t.0.relativePath)") }
            if needed > free { log("WARNING: this won't fit — \(neededStr) needed, \(freeStr) free.") }
            finish("Check done — \(todo.count) tracks (\(neededStr)) would be added.")
            return
        }
        if todo.isEmpty && !freshDB {
            finish("Nothing to do — “\(ipod.name)” already has this music.")
            return
        }
        if needed > free {
            finish("Not enough room on “\(ipod.name)”: \(neededStr) needed, \(freeStr) free. "
                 + "Nothing was copied.")
            return
        }

        let musicRoot = ipod.volumePath + "/iPod_Control/Music"
        do { try ensureMusicDirs(root: musicRoot) } catch {
            finish("Could not prepare the iPod: \(error.localizedDescription)"); return
        }

        post { self.total = Double(todo.count) }
        var added = 0, converted = 0, errors = 0
        var deviceLost = false
        var nextID = (db.tracks.map(\.id).max() ?? 51) + 1
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("syncopation", isDirectory: true)
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let journal = openCopyJournal(volume: ipod.volumePath)
        defer { try? journal?.close() }

        for (i, item) in todo.enumerated() {
            if cancelled { break }
            // The iPod can go away mid-copy; stop rather than failing every
            // remaining file one by one.
            if i % 10 == 0, !iPodStillConnected(ipod) { deviceLost = true; break }
            let (file, meta, convert) = item
            do {
                var payload = file.url
                var ext = (file.relativePath as NSString).pathExtension.lowercased()
                if convert {
                    let out = tmpDir.appendingPathComponent(UUID().uuidString + ".m4a")
                    try AudioConverter.convertToALAC(source: file.url, output: out,
                                                     sourceRate: meta.sampleRate)
                    payload = out
                    ext = "m4a"
                }
                let dest = try placeOnIPod(fileAt: payload, musicRoot: musicRoot, ext: ext)
                recordCopy(dest.path, journal: journal)
                if convert { try? fm.removeItem(at: payload) }
                let size = ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int64)
                    ?? file.size

                var t = IPodTrack()
                t.id = nextID; nextID += 1
                t.dbid = UInt64.random(in: 1...UInt64.max)
                t.title = meta.title
                t.artist = meta.artist
                t.album = meta.album
                t.albumArtist = meta.albumArtist
                t.genre = meta.genre
                t.composer = meta.composer
                let ft = ipodFiletype(ext: ext, converted: convert)
                t.filetypeMarker = ft.marker
                t.filetypeDescription = ft.description
                t.ipodPath = ipodPathString(for: dest, volume: ipod.volumePath)
                t.size = UInt32(clamping: size)
                t.lengthMS = UInt32(clamping: meta.durationMS)
                t.trackNr = UInt32(clamping: meta.trackNr)
                t.trackCount = UInt32(clamping: meta.trackCount)
                t.cdNr = UInt32(clamping: meta.discNr)
                t.cdCount = UInt32(clamping: meta.discCount)
                t.year = UInt32(clamping: meta.year)
                var rate = meta.sampleRate
                if convert { rate = AudioConverter.iPodSampleRate(for: rate) }
                t.samplerate = UInt32(clamping: rate)
                if meta.durationMS > 0 {
                    t.bitrate = UInt32(clamping: Int(size) * 8 / meta.durationMS)
                }
                t.timeAdded = macTimeNow()
                t.timeModified = macTimeNow()

                db.tracks.append(t)
                manifest.entries[file.relativePath] = file.size
                known.insert(tagKey(title: t.title, artist: t.artist, album: t.album))
                added += 1
                if convert { converted += 1 }
                log("\(convert ? "CONVERTED" : "COPIED   ")  \(file.relativePath)")
            } catch {
                errors += 1
                log("ERROR      \(file.relativePath): \(error.localizedDescription)")
                if !iPodStillConnected(ipod) { deviceLost = true; break }
            }
            let n = Double(i + 1)
            post { self.done = n; self.status = "Adding… \(Int(n))/\(todo.count)" }
        }

        if deviceLost {
            post { self.refreshIPods() }
            finish("“\(ipod.name)” was unplugged during the sync — \(added) of \(todo.count) "
                 + "tracks had been copied, and they weren't added to the library. Plug it back "
                 + "in and sync again; the leftover files are tidied up automatically.")
            return
        }

        if added > 0 || freshDB {
            post { self.status = "Updating the iPod's library…" }
            do {
                try writeIPodDatabase(db, to: ipod)
                saveManifest(manifest, volume: ipod.volumePath)
                resetCopyJournal(journal)
                log("Library updated: \(db.tracks.count) tracks.")
            } catch {
                finish("Copied \(added) files, but updating the library failed: "
                     + "\(error.localizedDescription) The previous library was kept.")
                return
            }
        }
        var summary = cancelled ? "Stopped — \(added) tracks added"
                                : "Done — \(added) tracks added (\(converted) converted)"
        summary += ", \(alreadySynced + alreadyThere) skipped"
        if errors > 0 { summary += ", \(errors) errors" }
        finish(summary + ". Eject the iPod before unplugging.")
    }

    // MARK: - Erase (a separate, deliberate action)

    func eraseDestination() {
        let fm = FileManager.default
        if mode == .ipod {
            guard let ipod = selectedIPod else {
                alert("Select an iPod first."); return
            }
            let count = ipodMusicFiles(volume: ipod.volumePath).count
            guard count > 0 else {
                alert("“\(ipod.name)” has no music on it — there's nothing to erase."); return
            }
            guard confirmErase(
                title: "Erase all music from “\(ipod.name)”?",
                body: """
                \(count) file\(count == 1 ? "" : "s") will be permanently deleted, including \
                music put there by other programs, and the iPod's library will be emptied.

                The iPod's own menus and settings are left alone, and nothing is copied \
                afterwards — this only erases. It can't be undone.
                """,
                button: "Erase") else { return }
            beginRun("Erasing…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                eraseIPod(ipod)
            }
        } else {
            let dst = destPath.trimmingCharacters(in: .whitespaces)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dst, isDirectory: &isDir), isDir.boolValue else {
                alert("Choose a valid destination first."); return
            }
            let items = ((try? fm.contentsOfDirectory(atPath: dst)) ?? [])
                .filter { !junkNames.contains($0) }
            guard !items.isEmpty else {
                alert("“\(dst)” is already empty."); return
            }
            guard confirmErase(
                title: "Erase everything in “\(dst)”?",
                body: """
                \(items.count) item\(items.count == 1 ? "" : "s") will be permanently deleted — \
                every file and folder inside, not just the types this mode syncs.

                Deleted items don't go to the Trash, nothing is copied afterwards, and this \
                can't be undone.
                """,
                button: "Erase") else { return }
            beginRun("Erasing…")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                var deleted = 0, failed = 0
                for name in items {
                    if cancelled { break }
                    do { try fm.removeItem(atPath: dst + "/" + name); deleted += 1 }
                    catch { failed += 1; log("ERROR   could not delete \(name)") }
                }
                finish("Done — \(deleted) items deleted"
                     + (failed > 0 ? ", \(failed) could not be removed." : "."))
            }
        }
    }

    private func eraseIPod(_ ipod: IPodDevice) {
        let fm = FileManager.default
        // Empty the library first: if that fails, the music is still listed and
        // playable rather than orphaned.
        var db = IPodDatabase()
        if let data = try? Data(contentsOf: URL(fileURLWithPath:
                ipod.volumePath + "/iPod_Control/iTunes/iTunesDB")),
           let existing = try? ITunesDBParser.parse(data) {
            db = existing
            db.tracks = []
            for i in db.playlists.indices { db.playlists[i].memberIDs = [] }
            for i in db.mhsd5Playlists.indices { db.mhsd5Playlists[i].memberIDs = [] }
        }
        if db.masterPlaylistIndex == nil {
            var mpl = IPodPlaylist()
            mpl.isMaster = true
            mpl.name = ipod.name
            db.playlists.insert(mpl, at: 0)
        }
        do { try writeIPodDatabase(db, to: ipod) } catch {
            finish("Could not empty the iPod's library: \(error.localizedDescription). "
                 + "Nothing was deleted."); return
        }
        let files = ipodMusicFiles(volume: ipod.volumePath)
        post { self.total = Double(files.count) }
        var deleted = 0
        for (i, p) in files.enumerated() {
            if cancelled { break }
            if (try? fm.removeItem(atPath: p)) != nil { deleted += 1 }
            let n = Double(i + 1)
            post { self.done = n; self.status = "Erasing… \(Int(n))/\(files.count)" }
        }
        try? fm.removeItem(atPath: ipod.volumePath + "/iPod_Control/Syncopation")
        post { self.refreshIPods() }
        finish("Done — \(deleted) files deleted from “\(ipod.name)”. Eject before unplugging.")
    }

    private func confirmErase(title: String, body: String, button: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .critical
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: button)
        return a.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - Interface

struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Progress will appear here." : text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .id("end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = SyncModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode:").bold()
            Picker("Mode", selection: $model.mode) {
                ForEach(SyncMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .disabled(model.running)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").foregroundColor(.secondary).padding(.top, 2)
                Text(model.mode.details)
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

            Text("Source folder:").bold().padding(.top, 6)
            HStack {
                TextField("The folder to copy from", text: $model.sourcePath)
                Button("Choose…") {
                    model.chooseFolder(message: "Choose the folder to copy from",
                                       initial: model.sourcePath) { model.sourcePath = $0 }
                }
            }

            if model.mode == .ipod { ipodDestination } else { folderDestination }

            HStack(spacing: 10) {
                Button("Check First") { model.start(dryRun: true) }.disabled(model.running)
                Button("Sync") { model.start(dryRun: false) }
                    .disabled(model.running)
                    .keyboardShortcut(.defaultAction)
                Button("Stop") { model.cancel() }.disabled(!model.running)
            }
            .padding(.top, 10)

            ProgressView(value: model.done, total: max(model.total, 1))
            Text(model.status).font(.callout)
            LogView(text: model.logText)
        }
        .padding(14)
        .frame(minWidth: 620, minHeight: 640)
    }

    @ViewBuilder
    private var folderDestination: some View {
        Text("Destination (SD card or folder):").bold().padding(.top, 6)
        HStack {
            TextField("Where to copy to", text: $model.destPath)
            Menu("Disks") {
                if model.volumes.isEmpty { Text("No removable disks found") }
                ForEach(model.volumes, id: \.self) { v in
                    Button(v) { model.destPath = v }
                }
            }
            .frame(width: 90)
            Button("Browse…") {
                model.chooseFolder(message: "Choose where to copy to",
                                   initial: model.destPath.isEmpty ? "/Volumes" : model.destPath) {
                    model.destPath = $0
                }
            }
            Button("Erase…") { model.eraseDestination() }.disabled(model.running)
            Button("Eject") { model.eject() }
                .disabled(model.running || !model.destIsEjectable)
        }
    }

    @ViewBuilder
    private var ipodDestination: some View {
        Text("iPod:").bold().padding(.top, 6)
        HStack {
            Menu {
                if model.ipods.isEmpty {
                    Text("No iPods found — connect one in disk mode, then Refresh")
                }
                ForEach(model.ipods) { pod in
                    Button { model.selectIPod(pod) } label: {
                        Label("\(pod.name) — \(pod.family)", systemImage: "ipod")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ipod")
                        .foregroundStyle(model.selectedIPod?.shellColor ?? .secondary)
                    Text(model.selectedIPod.map { "\($0.name) — \($0.family)" } ?? "Select iPod…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Refresh") { model.refreshIPods() }
            Button("Erase…") { model.eraseDestination() }
                .disabled(model.running || model.selectedIPod == nil)
            Button("Eject") { model.eject() }
                .disabled(model.running || !model.destIsEjectable)
        }
        if let pod = model.selectedIPod {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "ipod").foregroundStyle(pod.shellColor).padding(.top, 2)
                Text(pod.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }
}

@main
struct SyncopationApp: App {
    var body: some Scene {
        WindowGroup("Syncopation") {
            ContentView().onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}
