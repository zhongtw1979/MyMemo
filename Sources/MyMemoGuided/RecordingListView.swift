import SwiftUI
import AppKit
import MyMemoCore
import MyMemoExperience

struct GuidedRecordingPage: View {
    @ObservedObject var model: AppModel
    @StateObject private var browser: RecordingBrowserModel
    @FocusState private var searchFocused: Bool

    init(model: AppModel) {
        self.model = model
        _browser = StateObject(wrappedValue: RecordingBrowserModel(indexURL: model.dataDirectory.appendingPathComponent("transcript-search.sqlite3")))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("我的录音").font(.system(size: 28, weight: .bold))
                    Text("按名称、时间或大小排序，也能搜索文字稿中的一句话。").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("生成文字") { model.startTranscription() }.buttonStyle(SecondaryButtonStyle())
                    .disabled(model.busy || model.loadingLibrary || !model.recordings.contains { $0.status == .queued })
            }
            HStack(spacing: 10) {
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command).help("搜索录音（⌘F）")
                TextField("搜索录音名称、设备或文字稿正文", text: $browser.query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($searchFocused)
                    .accessibilityLabel("搜索录音名称、设备或文字稿正文")
                if !browser.query.isEmpty {
                    Button { browser.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).help("清空搜索")
                }
            }.padding(13).background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(searchFocused ? MemoStyle.green : MemoStyle.line, lineWidth: searchFocused ? 1.5 : 1))
            HStack(spacing: 16) {
                Picker("状态", selection: $browser.filter) {
                    Text("全部录音").tag("all")
                    Text("待生成文字").tag("queued")
                    Text("正在转写").tag("transcribing")
                    Text("已有文字稿").tag("done")
                    Text("需要处理").tag("failed")
                    Text("已跳过").tag("excluded")
                }.frame(width: 160)
                Picker("排序", selection: Binding(get: { browser.sort }, set: { browser.setSort($0, ascending: $0.defaultAscending) })) {
                    ForEach(RecordingSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 160)
                Button { browser.setSort(browser.sort, ascending: !browser.ascending) } label: {
                    Label(browser.sort.directionTitle(ascending: browser.ascending), systemImage: browser.ascending ? "arrow.up" : "arrow.down")
                }.buttonStyle(.bordered).help("切换升序或降序")
                Spacer(minLength: 0)
                Toggle("搜索正文", isOn: $browser.includeBody).toggleStyle(.checkbox).font(.callout)
            }
            HStack(spacing: 9) {
                if browser.isSearching || browser.isIndexing { ProgressView().controlSize(.small) }
                Text(browser.query.isEmpty ? "显示 \(browser.visible.count) 条" : "找到 \(browser.visible.count) 条录音").font(.caption.weight(.medium))
                if browser.isIndexing {
                    Text("正在建立正文索引 \(browser.indexed)/\(browser.indexTotal)").font(.caption).foregroundStyle(.secondary)
                } else if browser.unavailable > 0 {
                    Text("\(browser.unavailable) 份文字稿暂未索引").font(.caption).foregroundStyle(.orange)
                        .help("文件可能缺失、无法读取或超过 32 MiB。文件名搜索仍可使用。")
                } else { Text("共 \(model.snapshot.jobs.count) 条记录").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("刷新正文索引") { browser.rebuildIndex() }.buttonStyle(.plain).font(.caption).foregroundStyle(MemoStyle.green)
                    .disabled(browser.isIndexing || model.loadingLibrary)
            }
            if let error = browser.indexError {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.loadingLibrary {
                VStack(spacing: 14) { ProgressView(); Text("正在读取录音清单…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if browser.visible.isEmpty && !browser.isSearching {
                ContentUnavailableView {
                    Label(browser.query.isEmpty ? "暂无符合条件的录音" : "没有找到匹配的录音", systemImage: "magnifyingglass")
                } description: {
                    Text(browser.isIndexing ? "正文索引仍在建立，结果会自动补充。" : "可以换一个关键词，或清除筛选条件。")
                } actions: {
                    Button("显示全部录音") { browser.query = ""; browser.filter = "all" }.buttonStyle(SecondaryButtonStyle())
                    Button("导入文件夹") { model.chooseImportFolder() }.buttonStyle(SecondaryButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    HSplitView {
                        table.frame(minWidth: 500, idealWidth: 540, maxHeight: .infinity)
                        if let job = model.snapshot.jobs.first(where: { $0.id == model.selectedID }) {
                            RecordingDocumentPane(job: job, model: model, query: browser.query).id(job.id)
                                .frame(minWidth: 280, idealWidth: 350, maxHeight: .infinity)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }.background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
        }.padding(24)
            .onAppear { browser.setJobs(model.snapshot.jobs) }
            .onChange(of: model.snapshot.jobs) { _, jobs in browser.setJobs(jobs) }
            .onChange(of: browser.visible.map(\.id)) { _, ids in
                if let selected = model.selectedID, !ids.contains(selected) { model.selectedID = nil }
            }
            .onDisappear { browser.stop() }
    }

    private var table: some View {
        Table(browser.visible, selection: $model.selectedID, sortOrder: tableSort) {
            TableColumn("录音名称", value: \.originalName) { job in
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.originalName).font(.system(size: 13, weight: .medium)).lineLimit(2).help(job.originalName)
                    Text(job.deviceName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 3)
            }.width(min: 150, ideal: 220)
            TableColumn("导入时间", value: \.importedAt) { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.importedAt, format: .dateTime.year().month(.twoDigits).day(.twoDigits)).font(.system(size: 11))
                    Text(job.importedAt, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.width(95)
            TableColumn("大小", value: \.byteCount) { job in
                Text(ByteCountFormatter.string(fromByteCount: job.byteCount, countStyle: .file)).font(.system(size: 11))
            }.width(65)
            TableColumn("状态", value: \.status.title) { job in
                Text(job.status == .done ? "已有文字" : job.status == .queued ? "已保存" : job.status.title)
                    .font(.system(size: 11)).foregroundStyle(job.status == .failed ? .orange : MemoStyle.green)
            }.width(78)
        }.tableStyle(.inset(alternatesRowBackgrounds: true))
    }
    private var tableSort: Binding<[KeyPathComparator<RecordingJob>]> {
        Binding(get: {
            let order: SortOrder = browser.ascending ? .forward : .reverse
            switch browser.sort {
            case .name: return [KeyPathComparator(\RecordingJob.originalName, order: order)]
            case .device: return [KeyPathComparator(\RecordingJob.deviceName, order: order)]
            case .size: return [KeyPathComparator(\RecordingJob.byteCount, order: order)]
            case .status: return [KeyPathComparator(\RecordingJob.status.title, order: order)]
            case .importedAt: return [KeyPathComparator(\RecordingJob.importedAt, order: order)]
            }
        }, set: { values in
            guard let value = values.first else { return }
            let field: RecordingSort
            switch value.keyPath {
            case \RecordingJob.originalName: field = .name
            case \RecordingJob.deviceName: field = .device
            case \RecordingJob.byteCount: field = .size
            case \RecordingJob.status.title: field = .status
            default: field = .importedAt
            }
            browser.setSort(field, ascending: value.order == .forward)
        })
    }
}

private struct RecordingDocumentPane: View {
    let job: RecordingJob
    @ObservedObject var model: AppModel
    let query: String
    @StateObject private var selection: TranscriptSelection

    init(job: RecordingJob, model: AppModel, query: String) {
        self.job = job; self.model = model; self.query = query
        _selection = StateObject(wrappedValue: TranscriptSelection(reader: model.transcriptReader))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Text(job.originalName).font(.system(size: 16, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 6)
                    Button { model.selectedID = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭预览，展开清单")
                }
                HStack {
                    Button("录音位置") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.localPath)]) }
                    if let path = job.transcriptPath {
                        Button("打开文字稿") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                        Spacer(minLength: 0)
                        Button { selection.select(path: path, force: true) } label: { Image(systemName: "arrow.clockwise") }
                            .help("重新读取文字稿；外部编辑后可点击刷新")
                    }
                }.controlSize(.small)
                if let error = job.lastError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if job.status == .failed { Button("重新生成文字") { model.retry(id: job.id) }.buttonStyle(.bordered) }
            }.padding(18)
            Divider()
            switch selection.state {
            case .idle:
                Text(job.transcriptPath != nil ? "正在准备文字稿…" : job.status == .excluded ? "这份文件已跳过，不会转写。" : "录音已保存，文字稿生成后会显示在这里。")
                    .foregroundStyle(.secondary).padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loading:
                VStack(spacing: 12) { ProgressView(); Text("正在读取文字稿…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 16) {
                    Label("文字稿暂时无法显示", systemImage: "doc.badge.ellipsis").font(.headline)
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("重新加载") { selection.select(path: job.transcriptPath, force: true) }.buttonStyle(SecondaryButtonStyle())
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .loaded(let document):
                if document.truncated {
                    Text("长文已先载入前 \(document.characterCount) 字，可打开原文件查看全文。").font(.caption).foregroundStyle(.secondary).padding(12)
                }
                NativeTranscriptView(document: document, query: query).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text("\(document.characterCount) 字").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(document.truncated ? "复制当前预览" : "复制全文") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(document.text, forType: .string)
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(MemoStyle.green)
                }.padding(12)
            }
        }.background(.white)
            .task(id: job.transcriptPath) { selection.select(path: job.transcriptPath) }
            .onDisappear { selection.cancel() }
    }
}
