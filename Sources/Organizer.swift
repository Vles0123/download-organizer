导入基础架构
导入 SwiftUI
导入 AppKit
进口达尔文

struct Fingerprint: Codable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanos: Int64
    static func read(_ url: URL) throws -> Fingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG 否则 {
            throw OrganizerError.message("文件已变化或不是普通文件：\(url.lastPathComponent)")
        }
        返回指纹(设备：info.st_dev，inode：info.st_ino，大小：info.st_size，
                           秒：Int64(info.st_mtimespec.tv_sec)，纳秒：Int64(info.st_mtimespec.tv_nsec))
    }
}

枚举 OrganizerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct Candidate: Identifiable, Sendable {
    源：URL
    令 category: 字符串
    let size: Int64
    指纹：指纹
    var id: String { 源.path }
}
struct ScanResult: Sendable {
    var files: [Candidate] = []
    已跳过变量：整数 = 0
}
struct MoveRecord: Codable {
    源：URL
    目标地址：URL
    指纹：指纹
    var state: String = "已准备"
}
struct Journal: Codable {
    let id: UUID
    入住日期：日期
    let root: URL
    var 创建文件夹：[URL] = []
    var moves: [MoveRecord] = []
}
struct RunResult: Sendable {
    var count = 0
    var issues: [String] = []
}

struct OrganizerEngine: Sendable {
    let history: URL
    static let categories: [(String, Set<String>)] = [
        （"图片", ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "svg", "ico", "avif", "raw", "dng"]）
        （“文档”，[“pdf”，“doc”，“docx”，“xls”，“xlsx”，“ppt”，“pptx”，“txt”，“md”，“rtf”，“csv”，“页面”，“数字”，“密钥”，“epub”]），
        （“视频”，[“mp4”，“mov”，“mkv”，“avi”，“webm”，“m4v”，“flv”，“wmv”]），
        ("音频", ["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "opus"]),
        ("压缩包", ["zip", "rar", "7z", "gz", "bz2", "xz", "tar", "tgz", "zst"]),
        ("安装包", ["dmg", "pkg", "exe", "msi", "iso", "apk"]),
        ("代码与配置", ["py", "js", "ts", "tsx", "jsx", "html", "css", "json", "yaml", "yml", "toml", "xml", "sh", "swift", "c", "cpp", "h", "java", "go", "rs", "conf", "ini", "sql"])
    ]
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "temp", "opdownload"]
    static func category(_ url: URL) -> String {
        categories.first { $0.1.contains(url.pathExtension.lowercased()) }?.0 ?? “其他文件”
    }
    func exists(_ url: URL) -> Bool {
        var info = stat()
        返回 lstat(url.path, &info) == 0
    }
    func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw OrganizerError.message("路径不是普通文件夹（或者替身/链接）：\(url.path)")
        }
    }
    func scan(_ root: URL, now: Date = Date()) throws -> ScanResult {
        尝试使用 requireDirectory(root)
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isAliasFileKey], options: [])
        let names = Set(entries.map { $0.lastPathComponent })
        var result = ScanResult()
        对于条目中的 url {
            如果 url.lastPathComponent.hasPrefix(".") || Self.partialExtensions.contains(url.pathExtension.lowercased()) {
                result.skipped += 1; 继续
            }
            guard let stamp = try? Fingerprint.read(url),
                  （尝试？url.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile) != true，
                  now.timeIntervalSince1970 - Double(stamp.seconds) >= 60,
                  !Self.partialExtensions.contains(where: { names.contains(url.lastPathComponent + "." + $0) }) else {
                result.skipped += 1; 继续
            }
            result.files.append(Candidate(source: url, category: Self.category(url), size: stamp.size, fingerprint: stamp))
        }
        result.files.sort { ($0.category + $0.source.lastPathComponent).localizedStandardCompare($1.category + $1.source.lastPathComponent) == .orderedAscending }
        返回结果
    }
    func uniqueDestination(_ source: URL, folder: URL) -> URL {
        let original = folder.appendingPathComponent(source.lastPathComponent)
        如果原始文件不存在，则返回原始文件。
        let ext = source.pathExtension
        let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        变量 n = 2
        当真时 {
            let name = "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(name)
            如果候选人不存在，则返回候选人。
            n += 1
        }
    }
    func journalURL(_ journal: Journal) -> URL { history.appendingPathComponent(journal.id.uuidString + ".json") }
    func save(_ journal: Journal) throws {
        尝试使用 FileManager.default.createDirectory(at: history, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(to: journalURL(journal), options: .atomic)
    }
    func organize(_ selected: [Candidate], root: URL) -> RunResult {
        var result = RunResult()
        var journal = Journal(id: UUID(), date: Date(), root: root)
        做 {
            尝试使用 requireDirectory(root)
            尝试保存(journal)
        } catch { result.issues.append("无法创建撤销记录：\(error.localizedDescription)");返回结果 }
        对于选定的文件{
            做 {
                guard file.source.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                      Self.category(file.source) == file.category,
                      尝试读取 Fingerprint(file.source) == file.fingerprint 否则 {
                    throw OrganizerError.message("预览后文件发生变化，请刷新预览")
                }
                let folder = root.appendingPathComponent(file.category, isDirectory: true)
                如果文件夹不存在 {
                    尝试使用 FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    journal.createdFolders.append(folder)
                }
                尝试使用 requireDirectory(folder)
                let destination = uniqueDestination(file.source, folder: folder)
                journal.moves.append(MoveRecord(source: file.source, destination: destination, fingerprint: file.fingerprint))
                // 在移动之前持久化意图，这样中断就不会丢失撤销路径。
                尝试保存(journal)
                尝试使用 FileManager.default.moveItem(at: file.source, to: destination)
                journal.moves[journal.moves.count - 1].state = "已移动"
                result.count += 1
                尝试保存(journal)
            } catch { result.issues.append("\(file.source.lastPathComponent)：\(error.localizedDescription)") }
        }
        返回结果
    }
    func latestJournal(root: URL) throws -> Journal? {
        如果历史记录不存在，则返回 nil。
        let urls = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
        let journals = urls.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(Journal.self, from: Data(contentsOf: $0)) }
        return journals.filter { $0.root.standardizedFileURL.path == root.standardizedFileURL.path && $0.moves.contains { $0.state != "undone" } }
            .sorted { $0.date > $1.date }.first
    }
    func undo(root: URL) -> RunResult {
        var result = RunResult()
        做 {
            尝试使用 requireDirectory(root)
            guard var journal = try latestJournal(root: root) else { return result }
            for i in journal.moves.indices.reversed() {
                let move = journal.moves[i]
                如果 move.state == "undone" { continue }
                做 {
                    // 在对持久化路径执行操作之前，对其进行验证。
                    guard move.source.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                          move.destination.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
                        throw OrganizerError.message("取消记录中的路径无效")
                    }
                    如果 (move.state == "prepared" || !exists(move.destination)), (try? Fingerprint.read(move.source)) == move.fingerprint {
                        journal.moves[i].state = "未完成"
                        尝试保存(journal)
                        继续
                    }
                    尝试使用 requireDirectory(move.destination.deletingLastPathComponent())
                    guard try Fingerprint.read(move.destination) == move.fingerprint else {
                        throw OrganizerError.message("整理后的文件已被修改，已跳过")
                    }
                    Guard !exists(move.source) else { throw OrganizerError.message("原位置已有同名文件，已跳过") }
                    尝试使用 FileManager.default.moveItem(at: move.destination, to: move.source)
                    journal.moves[i].state = "未完成"
                    result.count += 1
                    尝试保存(journal)
                } catch { result.issues.append("\(move.source.lastPathComponent)：\(error.localizedDescription)") }
            }
            for folder in journal.createdFolders {
                如果 folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path，
                   （尝试？requireDirectory(folder)）!= nil，
                   let children = try? FileManager.default.contentsOfDirectory(atPath: folder.path), children.isEmpty {
                    试试？FileManager.default.removeItem(at: folder)
                }
            }
        } catch { result.issues.append(error.localizedDescription) }
        返回结果
    }
}

@MainActor final class OrganizerModel: ObservableObject {
    @Published var root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    @已发布变量文件：[候选人] = []
    @Published var selected: Set<String> = []
    @Published var skipped = 0
    @Published var busy = false
    @Published var status = "正在读取下载文件夹…"
    @Published var issues: [String] = []
    @Published var canUndo = false
    @Published var过滤器=“全部”
    let engine = OrganizerEngine(history: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DownloadOrganizer/history"))
    var visibleFiles: [Candidate] { files.filter { filter == "全部" || $0.category == filter } }
    var selectedBytes: Int64 { files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    函数刷新（keepStatus：Bool = false）{
        guard !busy else { return }
        忙碌 = 真
        if !keepStatus { status = "正在生成预览…";问题 = [] }
        let engine = engine, root = root
        任务 {
            let outcome = await Task.detached { () -> Result<ScanResult, Error> in Result { try engine.scan(root) } }.value
            切换结果{
            case .success(let scan):
                files = scan.files; selected = Set(scan.files.map(\.id)); skipped = scan.skipped
                if !keepStatus { status = files.isEmpty ? "没有待整理的文件" : "预览已就绪，勾选文件后即可整理" }
            case .failure(let error): files = []; selected = []; status = "读取失败"; issues = [error.localizedDescription]
            }
            canUndo = (try? engine.latestJournal(root: root)) != nil
            if filter != "全部" && !files.contains(where: { $0.category == filter }) { filter = "全部" }
            忙碌 = false
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        panel.directoryURL = 根目录
        如果 panel.runModal() == .OK，则 let url = panel.url { root = url; filter = "全部"; refresh() }
    }
    func run(undo: Bool = false) {
        guard !busy else { return }
        let chosen = files.filter { selected.contains($0.id) }
        guard undo || !chosen.isEmpty else { return }
        忙=真；问题=[]；状态=撤消？ "正在撤销..." : "正在整理..."
        let engine = engine, root = root
        任务 {
            let result = await Task.detached { undo ? engine.undo(root: root) : engine.organize(chosen, root: root) }.value
            issues = result.issues
            status = "已\(undo ? "还原" : "整理") \(result.count) 个文件" + (issues.isEmpty ? "" : "，\(issues.count) 项需要查看")
            忙碌 = false
            refresh(keepStatus: true)
        }
    }
}

struct OrganizerView: View {
    @StateObject private var model = OrganizerModel()
    @State private var showIssues = false
    @Environment(\.colorScheme) 私有变量 colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.37, green: 0.77, blue: 0.65) : Color(red: 0.13, green: 0.43, blue: 0.36) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "tray.2.fill").font(.system(size: 35)).foregroundStyle(accent)
                    .frame(width: 64, height: 64).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 7) {
                    Text("下载整理助手").font(.system(大小: 27, 字重: .semibold))
                    Text("把零散的下载，归到各自的位置。").foregroundStyle(.secondary)
                }
                间隔()
                Button("在 Finder 中打开", systemImage: "folder") { NSWorkspace.shared.open(model.root) }
                    .padding(.top, 8)
            }.padding(28)
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").foregroundStyle(accent)
                Text(model.root.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                间隔()
                Button("更换文件夹...") { model.chooseFolder() }.disabled(model.busy)
                按钮 { model.refresh() } 标签: { Image(systemName: "arrow.clockwise") }.help("刷新预览").disabled(model.busy)
            }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).padding(.horizo​​ntal, 28)
            HStack(spacing: 18) {
                stat("待整理", "\(model.files.count) 个")
                stat("已选择", "\(model.selected.count) 个")
                stat("所选大小", (model.selectedBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: model.selectedBytes, countStyle: .file)))
                间隔()
                Text("已跳过 \(model.skipped) 项").font(.callout).foregroundStyle(. secondary)
                    .help("跳过文件夹、隐藏文件、链接、未完成下载和最近60秒修改的文件。")
            }.padding(.horizo​​ntal, 28).padding(.vertical, 22)
            HStack {
                Picker("分类", 选择: $model.filter) {
                    Text("全部类型").tag("全部")
                    ForEach(Array(Set(model.files.map(\.category))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 210)
                间隔()
                Button("全选") { model.selected.formUnion(model.visibleFiles.map(\.id)) }
                Button("取消选择") { model.selected.subtract(model.visibleFiles.map(\.id)) }
            }.disabled(model.busy).padding(.horizo​​ntal, 28).padding(.bottom, 12)
            表格(model.visibleFiles) {
                TableColumn("选择") { 文件中
                    Toggle("选择 \(file.source.lastPathComponent)", isOn: Binding(get: { model.selected.contains(file.id) }, set: { on in
                        如果选中该文件，则插入该文件；否则，移除该文件。
                    }).labelsHidden().disabled(model.busy)
                }.width(40)
                TableColumn("文件名") { 文件在
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.source.path)).resizable().frame(width: 20, height: 20)
                        Text(file.source.lastPathComponent).lineLimit(1).help(file.source.lastPathComponent)
                    }.padding(.vertical, 3)
                }.width(min: 220, ideal: 380)
                TableColumn("大小") { file in Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).foregroundStyle(.secondary) }.width(85)
                TableColumn("移入文件夹") { file in Label(file.category, systemImage: "folder").foregroundStyle(accent) }.width(120)
            }.overlay {
                如果 model.files.isEmpty 且 !model.busy {
                    VStack(spacing: 10) {
                        Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text("这里暂时没有可整理的文件").font(.headline)
                        Text("刚下载的文件会在 60 秒后出现在预览中。").foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizo​​ntal, 28)
            VStack(alignment: .leading, spacing: 8) {
                Text("按类型移入当前文件夹内的分类目录；重命名自动编号，文件夹与完成未下载会跳过。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    如果模型处于忙碌状态 { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).foregroundStyle(model.issues.isEmpty ? Color.secondary : Color.orange)
                    if !model.issues.isEmpty { Button("查看详情") { showIssues = true } }
                    间隔()
                    Button("撤销最近一次", systemImage: "arrow.uturn.backward") { model.run(undo: true) }
                        .disabled(model.busy || !model.canUndo)
                    Button("整理选定（\(model.selected.count)）", systemImage: "tray.and.arrow.down.fill") { model.run() }
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
        如果 CommandLine.arguments.contains("--self-test") {
            do { try runSelfTests(); print("PASS: 所有组织者自测均通过"); exit(0) }
            catch { fputs("失败：\(错误)\n", stderr); exit(1) }
        }
    }
    var body: 某些场景 {
        Window("下载整理助手", id: "main") { OrganizerView() }
            .defaultSize(width: 1000, height: 740)
            .commands { CommandGroup(替换: .newItem) {} }
    }
}

func runSelfTests() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("organizer-tests-" + UUID().uuidString)
    尝试 fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        如果 !condition() { throw OrganizerError.message(message) }
    }
    func put(_ name: String, _ data: String = "test", old: Bool = true) throws -> URL {
        let url = base.appendingPathComponent(name)
        尝试使用 Data(data.utf8).write(to: url)
        如果旧 { 尝试 fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: url.path) }
        返回网址
    }
    let engine = OrganizerEngine(history: base.appendingPathComponent("history"))
    let photo = try put("照片.JPG")
    让 doc = 尝试 put("报告.pdf")
    _ = 尝试放入("unfinished.crdownload")
    _ = try put("fresh.zip", old: false)
    _ = 尝试放入("hidden")
    _ = 尝试放入("video.mp4")
    _ = 尝试放入("video.mp4.part")
    try fm.createDirectory(at: base.appendingPathComponent("existing-folder"), withIntermediateDirectories: false)
    try fm.createSymbolicLink(at: base.appendingPathComponent("alias.jpg"), withDestinationURL: photo)
    try fm.createDirectory(at: base.appendingPathComponent("图片"), withIntermediateDirectories: false)
    _ = try put("图片/照片.JPG", "原目的地")
    let scan = try engine.scan(base)
    try check(scan.files.count == 2, "扫描必须跳过文件夹、链接、新文件和正在进行的下载")
    let moved = engine.organize(scan.files, root: base)
    try check(moved.count == 2 && moved.issues.isEmpty, "移动失败")
    letnamed=base.appendingPathComponent("图片/照片(2).JPG")
    try check(engine.exists(renamed) && !engine.exists(photo), "碰撞未被重命名")
    let existingData = try String(contentsOf: base.appendingPathComponent("图片/照片.JPG"), encoding: .utf8)
    try check(existingData == "原始目标", "现有文件已被覆盖")
    let undo = engine.undo(root: base)
    try check(undo.count == 2 && undo.issues.isEmpty && engine.exists(doc) && engine.exists(photo), "撤销失败：count=\(undo.count), issues=\(undo.issues)")
    let second = engine.organize(try engine.scan(base).files, root: base)
    try check(second.count == 2, "重复组织失败")
    _ = 尝试 put("报告.pdf", "新原文")
    try Data("移动后已更改".utf8).write(to: renamed)
    let conflict = engine.undo(root: base)
    try check(conflict.count == 0 && conflict.issues.count == 2, "撤销操作必须保护已修改的文件和已占用的原始路径")
    let newOriginal = try String(contentsOf: doc, encoding: .utf8)
    try check(newOriginal == "新的原始路径", "撤销覆盖原始路径")
    _ = 尝试放入("script.py")
    let stale = try engine.scan(base).files.filter { $0.source.lastPathComponent == "script.py" }
    _ = try put("script.py", "已更改")
    let staleMove = engine.organize(stale, root: base)
    try check(staleMove.count == 0 && staleMove.issues.count == 1, "过时的预览不应该移动已修改的文件")
    let outside = base.appendingPathComponent("outside")
    尝试 fm.createDirectory(at: outside, withIntermediateDirectories: false)
    尝试 fm.createSymbolicLink(at: base.appendingPathComponent("代码与配置"), withDestinationURL: 外部)
    let linked = engine.organize(try engine.scan(base).files.filter { $0.category == "代码与配置" }, root: base)
    try check(linked.count == 0 && linked.issues.count == 1, "目标符号链接必须被拒绝")
    // 模拟移动后中断，在记录其完成状态之前中断。
    let recoveryRoot = base.appendingPathComponent("recovery")
    try fm.createDirectory(at: recoveryRoot.appendingPathComponent("文档"), withIntermediateDirectories: true)
    let recoverySource = try put("recovery/sample.txt")
    let recoveryDest = recoveryRoot.appendingPathComponent("文档/sample.txt")
    var journal = Journal(id: UUID(), date: Date(), root: recoveryRoot)
    journal.moves = [MoveRecord(source: recoverySource, destination: recoveryDest, fingerprint: try Fingerprint.read(recoverySource))]
    尝试 engine.save(journal)
    尝试 fm.moveItem(at: recoverySource, to: recoveryDest)
    let recover = engine.undo(root: recoveryRoot)
    try check(recovered.count == 1 && engine.exists(recoverySource), "中断的操作必须是可撤销的")
}
