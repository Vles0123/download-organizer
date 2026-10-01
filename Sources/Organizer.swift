import Foundation
import SwiftUI
import AppKit
import Darwin

struct Fingerprint: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanos: Int64
    static func read(_ url: URL) throws -> Fingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else {
            throw OrganizerError.message("文件已变化或不是普通文件：\(url.lastPathComponent)")
        }
        return Fingerprint(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                           seconds: Int64(info.st_mtimespec.tv_sec), nanos: Int64(info.st_mtimespec.tv_nsec))
    }
}

enum OrganizerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct Candidate: Identifiable, Sendable {
    let source: URL
    let category: String
    let size: Int64
    let fingerprint: Fingerprint
    var id: String { source.path }
}
struct ScanResult: Sendable {
    var files: [Candidate] = []
    var skipped: Int = 0
}
struct MoveRecord: Codable {
    let source: URL
    let destination: URL
    let fingerprint: Fingerprint
    var state: String = "prepared"
}
struct Journal: Codable {
    let id: UUID
    let date: Date
    let root: URL
    var createdFolders: [URL] = []
    var moves: [MoveRecord] = []
}
struct RunResult: Sendable {
    var count = 0
    var issues: [String] = []
}

struct OrganizerEngine: Sendable {
    let history: URL
    static let categories: [(String, Set<String>)] = [
        ("图片", ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg", "ico", "avif", "raw", "dng"]),
        ("文档", ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "csv", "pages", "numbers", "key", "epub"]),
        ("视频", ["mp4", "mov", "mkv", "avi", "webm", "m4v", "flv", "wmv"]),
        ("音频", ["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "opus"]),
        ("压缩包", ["zip", "rar", "7z", "gz", "bz2", "xz", "tar", "tgz", "zst"]),
        ("安装包", ["dmg", "pkg", "exe", "msi", "iso", "apk"]),
        ("代码与配置", ["py", "js", "ts", "tsx", "jsx", "html", "css", "json", "yaml", "yml", "toml", "xml", "sh", "swift", "c", "cpp", "h", "java", "go", "rs", "conf", "ini", "sql"])
    ]
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "temp", "opdownload"]
    static func category(_ url: URL) -> String {
        categories.first { $0.1.contains(url.pathExtension.lowercased()) }?.0 ?? "其他文件"
    }
    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw OrganizerError.message("路径不是普通文件夹（或是替身/链接）：\(url.path)")
        }
    }
    func scan(_ root: URL, now: Date = Date()) throws -> ScanResult {
        try requireDirectory(root)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isAliasFileKey], options: [])
        let names = Set(entries.map { $0.lastPathComponent })
        var result = ScanResult()
        for url in entries {
            if url.lastPathComponent.hasPrefix(".") || Self.partialExtensions.contains(url.pathExtension.lowercased()) {
                result.skipped += 1; continue
            }
            guard let stamp = try? Fingerprint.read(url),
                  (try? url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) != true,
                  now.timeIntervalSince1970 - Double(stamp.seconds) >= 60,
                  !Self.partialExtensions.contains(where: { names.contains(url.lastPathComponent + "." + $0) }) else {
                result.skipped += 1; continue
            }
            result.files.append(Candidate(source: url, category: Self.category(url), size: stamp.size, fingerprint: stamp))
        }
        result.files.sort { ($0.category + $0.source.lastPathComponent).localizedStandardCompare($1.category + $1.source.lastPathComponent) == .orderedAscending }
        return result
    }
    func uniqueDestination(_ source: URL, folder: URL) -> URL {
        let original = folder.appendingPathComponent(source.lastPathComponent)
        if !exists(original) { return original }
        let ext = source.pathExtension
        let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
    func journalURL(_ journal: Journal) -> URL { history.appendingPathComponent(journal.id.uuidString + ".json") }
    func save(_ journal: Journal) throws {
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL(journal), options: .atomic)
    }
    func organize(_ selected: [Candidate], root: URL) -> RunResult {
        var result = RunResult()
        var journal = Journal(id: UUID(), date: Date(), root: root)
        do {
            try requireDirectory(root)
            try save(journal)
        } catch { result.issues.append("无法创建撤销记录：\(error.localizedDescription)"); return result }
        for file in selected {
            do {
                guard file.source.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                      Self.category(file.source) == file.category,
                      try Fingerprint.read(file.source) == file.fingerprint else {
                    throw OrganizerError.message("预览后文件发生变化，请刷新预览")
                }
                let folder = root.appendingPathComponent(file.category, isDirectory: true)
                if !exists(folder) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    journal.createdFolders.append(folder)
                }
                try requireDirectory(folder)
                let destination = uniqueDestination(file.source, folder: folder)
                journal.moves.append(MoveRecord(source: file.source, destination: destination, fingerprint: file.fingerprint))
                // Persist intent before moving, so interruption does not lose the undo path.
                try save(journal)
                try FileManager.default.moveItem(at: file.source, to: destination)
                journal.moves[journal.moves.count - 1].state = "moved"
                result.count += 1
                try save(journal)
            } catch { result.issues.append("\(file.source.lastPathComponent)：\(error.localizedDescription)") }
        }
        return result
    }
    func latestJournal(root: URL) throws -> Journal? {
        if !exists(history) { return nil }
        let urls = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
        let journals = urls.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: $0)) }
        return journals.filter { $0.root.standardizedFileURL.path == root.standardizedFileURL.path && $0.moves.contains { $0.state != "undone" } }
            .sorted { $0.date > $1.date }.first
    }
    func undo(root: URL) -> RunResult {
        var result = RunResult()
        do {
            try requireDirectory(root)
            guard var journal = try latestJournal(root: root) else { return result }
            for i in journal.moves.indices.reversed() {
                let move = journal.moves[i]
                if move.state == "undone" { continue }
                do {
                    // Validate persisted paths before acting on them.
                    guard move.source.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                          move.destination.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
                        throw OrganizerError.message("撤销记录中的路径无效")
                    }
                    if (move.state == "prepared" || !exists(move.destination)), (try? Fingerprint.read(move.source)) == move.fingerprint {
                        journal.moves[i].state = "undone"
                        try save(journal)
                        continue
                    }
                    try requireDirectory(move.destination.deletingLastPathComponent())
                    guard try Fingerprint.read(move.destination) == move.fingerprint else {
                        throw OrganizerError.message("整理后的文件已被修改，已跳过")
                    }
                    guard !exists(move.source) else { throw OrganizerError.message("原位置已有同名文件，已跳过") }
                    try FileManager.default.moveItem(at: move.destination, to: move.source)
                    journal.moves[i].state = "undone"
                    result.count += 1
                    try save(journal)
                } catch { result.issues.append("\(move.source.lastPathComponent)：\(error.localizedDescription)") }
            }
            for folder in journal.createdFolders {
                if folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                   (try? requireDirectory(folder)) != nil,
                   let children = try? FileManager.default.contentsOfDirectory(atPath: folder.path), children.isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                }
            }
        } catch { result.issues.append(error.localizedDescription) }
        return result
    }
}

@MainActor final class OrganizerModel: ObservableObject {
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    @Published var files: [Candidate] = []
    @Published var selected: Set<String> = []
    @Published var skipped = 0
    @Published var busy = false
    @Published var status = "正在读取下载文件夹…"
    @Published var issues: [String] = []
    @Published var canUndo = false
    @Published var filter = "全部"
    let engine = OrganizerEngine(history: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DownloadOrganizer/history"))
    var visibleFiles: [Candidate] { files.filter { filter == "全部" || $0.category == filter } }
    var selectedBytes: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    func refresh(keepStatus: Bool = false) {
        guard !busy else { return }
        busy = true
        if !keepStatus { status = "正在生成预览…"; issues = [] }
        let engine = engine, root = root
        Task {
            let outcome = await Task.detached { () -> Result<ScanResult, Error> in Result { try engine.scan(root) } }.value
            switch outcome {
            case .success(let scan):
                files = scan.files; selected = Set(scan.files.map(\.id)); skipped = scan.skipped
                if !keepStatus { status = files.isEmpty ? "没有待整理的文件" : "预览已就绪，勾选文件后即可整理" }
            case .failure(let error): files = []; selected = []; status = "读取失败"; issues = [error.localizedDescription]
            }
            canUndo = (try? engine.latestJournal(root: root)) != nil
            if filter != "全部" && !files.contains(where: { $0.category == filter }) { filter = "全部" }
            busy = false
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url; filter = "全部"; refresh() }
    }
    func run(undo: Bool = false) {
        guard !busy else { return }
        let chosen = files.filter { selected.contains($0.id) }
        guard undo || !chosen.isEmpty else { return }
        busy = true; issues = []; status = undo ? "正在撤销…" : "正在整理…"
        let engine = engine, root = root
        Task {
            let result = await Task.detached { undo ? engine.undo(root: root) : engine.organize(chosen, root: root) }.value
            issues = result.issues
            status = "已\(undo ? "还原" : "整理") \(result.count) 个文件" + (issues.isEmpty ? "" : "，\(issues.count) 项需要查看")
            busy = false
            refresh(keepStatus: true)
        }
    }
}

struct OrganizerView: View {
    @StateObject private var model = OrganizerModel()
    @State private var showIssues = false
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.37, green: 0.77, blue: 0.65) : Color(red: 0.13, green: 0.43, blue: 0.36) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "tray.2.fill").font(.system(size: 35)).foregroundStyle(accent)
                    .frame(width: 64, height: 64).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 7) {
                    Text("下载整理助手").font(.system(size: 27, weight: .semibold))
                    Text("把零散的下载，归到各自的位置。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("在 Finder 中打开", systemImage: "folder") { NSWorkspace.shared.open(model.root) }
                    .padding(.top, 8)
            }.padding(28)
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").foregroundStyle(accent)
                Text(model.root.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("更换文件夹…") { model.chooseFolder() }.disabled(model.busy)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新预览").disabled(model.busy)
            }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 28)
            HStack(spacing: 18) {
                stat("待整理", "\(model.files.count) 个")
                stat("已选择", "\(model.selected.count) 个")
                stat("所选大小", (model.selectedBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: model.selectedBytes, countStyle: .file)))
                Spacer()
                Text("已跳过 \(model.skipped) 项").font(.callout).foregroundStyle(.secondary)
                    .help("跳过文件夹、隐藏文件、链接、未完成下载和最近 60 秒修改的文件。")
            }.padding(.horizontal, 28).padding(.vertical, 22)
            HStack {
                Picker("分类", selection: $model.filter) {
                    Text("全部类型").tag("全部")
                    ForEach(Array(Set(model.files.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
                Spacer()
                Button("全选") { model.selected.formUnion(model.visibleFiles.map(\.id)) }
                Button("取消选择") { model.selected.subtract(model.visibleFiles.map(\.id)) }
            }.disabled(model.busy).padding(.horizontal, 28).padding(.bottom, 12)
            Table(model.visibleFiles) {
                TableColumn("选择") { file in
                    Toggle("选择 \(file.source.lastPathComponent)", isOn: Binding(get: { model.selected.contains(file.id) }, set: { on in
                        if on { model.selected.insert(file.id) } else { model.selected.remove(file.id) }
                    })).labelsHidden().disabled(model.busy)
                }.width(40)
                TableColumn("文件名") { file in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.source.path)).resizable().frame(width: 20, height: 20)
                        Text(file.source.lastPathComponent).lineLimit(1).help(file.source.lastPathComponent)
                    }.padding(.vertical, 3)
                }.width(min: 220, ideal: 380)
                TableColumn("大小") { file in Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).foregroundStyle(.secondary) }.width(85)
                TableColumn("移入文件夹") { file in Label(file.category, systemImage: "folder").foregroundStyle(accent) }.width(120)
            }.overlay {
                if model.files.isEmpty && !model.busy {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("这里暂时没有可整理的文件").font(.headline)
                        Text("刚下载的文件会在 60 秒后出现在预览中。").foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 28)
            VStack(alignment: .leading, spacing: 8) {
                Text("按类型移入当前文件夹内的分类目录；重名自动编号，文件夹与未完成下载会跳过。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).foregroundStyle(model.issues.isEmpty ? Color.secondary : Color.orange)
                    if !model.issues.isEmpty { Button("查看详情") { showIssues = true } }
                    Spacer()
                    Button("撤销最近一次", systemImage: "arrow.uturn.backward") { model.run(undo: true) }
                        .disabled(model.busy || !model.canUndo)
                    Button("整理所选（\(model.selected.count)）", systemImage: "tray.and.arrow.down.fill") { model.run() }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                        .disabled(model.busy || model.selected.isEmpty)
                }
            }.padding(28)
        }.frame(minWidth: 900, minHeight: 650).background(Color(nsColor: .windowBackgroundColor))
            .task { model.refresh() }
            .sheet(isPresented: $showIssues) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("处理详情").font(.title2.bold())
                    ScrollView { Text(model.issues.joined(separator: "\n\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Spacer(); Button("关闭") { showIssues = false }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 620, height: 380)
            }
    }
    func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
        }.frame(minWidth: 95, alignment: .leading)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct DownloadOrganizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    init() {
        if CommandLine.arguments.contains("--self-test") {
            do { try runSelfTests(); print("PASS: all organizer self-tests"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        Window("下载整理助手", id: "main") { OrganizerView() }
            .defaultSize(width: 1000, height: 740)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

func runSelfTests() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("organizer-tests-" + UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw OrganizerError.message(message) }
    }
    func put(_ name: String, _ data: String = "test", old: Bool = true) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data(data.utf8).write(to: url)
        if old { try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path) }
        return url
    }
    let engine = OrganizerEngine(history: base.appendingPathComponent("history"))
    let photo = try put("照片.JPG")
    let doc = try put("报告.pdf")
    _ = try put("unfinished.crdownload")
    _ = try put("fresh.zip", old: false)
    _ = try put(".hidden")
    _ = try put("video.mp4")
    _ = try put("video.mp4.part")
    try fm.createDirectory(at: base.appendingPathComponent("existing-folder"), withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: base.appendingPathComponent("alias.jpg"), withDestinationURL: photo)
    try fm.createDirectory(at: base.appendingPathComponent("图片"), withIntermediateDirectories: false)
    _ = try put("图片/照片.JPG", "original destination")
    let scan = try engine.scan(base)
    try check(scan.files.count == 2, "Scan must skip folders, links, fresh files, and downloads in progress")
    let moved = engine.organize(scan.files, root: base)
    try check(moved.count == 2 && moved.issues.isEmpty, "Move failed")
    let renamed = base.appendingPathComponent("图片/照片 (2).JPG")
    try check(engine.exists(renamed) && !engine.exists(photo), "Collision was not renamed")
    let existingData = try String(contentsOf: base.appendingPathComponent("图片/照片.JPG"), encoding: .utf8)
    try check(existingData == "original destination", "Existing file was overwritten")
    let undo = engine.undo(root: base)
    try check(undo.count == 2 && undo.issues.isEmpty && engine.exists(doc) && engine.exists(photo), "Undo failed: count=\(undo.count), issues=\(undo.issues)")
    let second = engine.organize(try engine.scan(base).files, root: base)
    try check(second.count == 2, "Repeat organization failed")
    _ = try put("报告.pdf", "new original")
    try Data("changed after moving".utf8).write(to: renamed)
    let conflict = engine.undo(root: base)
    try check(conflict.count == 0 && conflict.issues.count == 2, "Undo must protect modified files and occupied original paths")
    let newOriginal = try String(contentsOf: doc, encoding: .utf8)
    try check(newOriginal == "new original", "Undo overwrote original path")
    _ = try put("script.py")
    let stale = try engine.scan(base).files.filter { $0.source.lastPathComponent == "script.py" }
    _ = try put("script.py", "changed")
    let staleMove = engine.organize(stale, root: base)
    try check(staleMove.count == 0 && staleMove.issues.count == 1, "Stale preview should not move modified files")
    let outside = base.appendingPathComponent("outside")
    try fm.createDirectory(at: outside, withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: base.appendingPathComponent("代码与配置"), withDestinationURL: outside)
    let linked = engine.organize(try engine.scan(base).files.filter { $0.category == "代码与配置" }, root: base)
    try check(linked.count == 0 && linked.issues.count == 1, "Destination symlinks must be refused")
    // Emulate interruption after a move, before its completed state was recorded.
    let recoveryRoot = base.appendingPathComponent("recovery")
    try fm.createDirectory(at: recoveryRoot.appendingPathComponent("文档"), withIntermediateDirectories: true)
    let recoverySource = try put("recovery/sample.txt")
    let recoveryDest = recoveryRoot.appendingPathComponent("文档/sample.txt")
    var journal = Journal(id: UUID(), date: Date(), root: recoveryRoot)
    journal.moves = [MoveRecord(source: recoverySource, destination: recoveryDest, fingerprint: try Fingerprint.read(recoverySource))]
    try engine.save(journal)
    try fm.moveItem(at: recoverySource, to: recoveryDest)
    let recovered = engine.undo(root: recoveryRoot)
    try check(recovered.count == 1 && engine.exists(recoverySource), "Interrupted moves must be undoable")
}
