import SwiftUI
import AppKit
import MyMemoCore

struct GuidedRecordingPage: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var filter = "all"
    private var jobs: [RecordingJob] {
        model.snapshot.jobs.reversed().filter {
            ((filter == "all" && $0.status != .excluded) || $0.status.rawValue == filter) &&
            (search.isEmpty || $0.originalName.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 7) { Text("我的录音").font(.system(size: 30, weight: .bold)); Text("录音、文字稿和处理结果，都能在这里找到。").foregroundStyle(.secondary) }
                Spacer()
                Button("生成文字") { model.startTranscription() }.buttonStyle(SecondaryButtonStyle()).disabled(model.busy || !model.recordings.contains { $0.status == .queued })
            }
            HStack(spacing: 14) {
                Picker("筛选录音", selection: $filter) {
                    Text("全部").tag("all"); Text("有文字稿").tag("done"); Text("需重试").tag("failed"); Text("已跳过").tag("excluded")
                }.pickerStyle(.segmented).frame(maxWidth: 330)
                TextField("搜索录音名称", text: $search).textFieldStyle(.roundedBorder)
            }
            if model.snapshot.jobs.isEmpty {
                ContentUnavailableView { Label("还没有录音", systemImage: "waveform") } description: { Text("连接已设置的设备，或选择电脑中的录音文件夹。") } actions: {
                    Button("导入文件夹") { model.chooseImportFolder() }.buttonStyle(PrimaryButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(jobs, selection: $model.selectedID) { job in GuidedRecordingRow(job: job).tag(job.id) }.listStyle(.plain).frame(minWidth: 240, idealWidth: 340)
                    if let job = model.snapshot.jobs.first(where: { $0.id == model.selectedID }) {
                        GuidedRecordingDetail(job: job, model: model).frame(minWidth: 300, idealWidth: 370)
                    } else { ContentUnavailableView("点选一份录音", systemImage: "doc.text.magnifyingglass", description: Text("查看文字稿或打开原始录音。")) .frame(minWidth: 300) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 16))
            }
        }.padding(30)
    }
}
private struct GuidedRecordingDetail: View {
    let job: RecordingJob
    @ObservedObject var model: AppModel
    @State private var transcript = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                Text(job.originalName).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text("\(job.deviceName) · \(ByteCountFormatter.string(fromByteCount: job.byteCount, countStyle: .file))").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("找到录音文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.localPath)]) }
                    if let path = job.transcriptPath { Button("打开文字稿") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
                }.controlSize(.small)
                if let error = job.lastError { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if job.status == .failed { Button("重新生成文字") { model.retry(id: job.id) }.buttonStyle(SecondaryButtonStyle()) }
                Divider()
                if transcript.isEmpty {
                    Text(job.status == .excluded ? "这份文件已跳过，不会自动转写。" : job.status == .done ? "文字稿暂时无法读取，可检查保存文件夹。" : "录音已经保存。生成文字后，会显示在这里。")
                        .foregroundStyle(.secondary).lineSpacing(5)
                } else {
                    Text("文字稿").font(.callout.weight(.semibold))
                    Text(transcript).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
                    Text("语音识别结果，重要内容建议结合录音核对。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.task(id: job.transcriptPath) {
            transcript = ""
            guard let path = job.transcriptPath else { return }
            transcript = await Task.detached {
                let text = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("txt")
                return (try? String(contentsOf: text, encoding: .utf8)) ?? ""
            }.value
        }
    }
}

struct FriendlySettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                Text("按你的习惯调整").font(.system(size: 30, weight: .bold))
                Text("换了录音笔，或想换保存位置？再走一次三步设置就好。").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 20) {
                    Label("当前使用方式", systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(MemoStyle.green)
                    LabeledContent("录音设备", value: model.configuration.devices.isEmpty ? "从文件夹导入 / 稍后连接" : model.configuration.devices.map(\.name).joined(separator: "、"))
                    LabeledContent("保存位置", value: URL(fileURLWithPath: model.configuration.destinationPath).lastPathComponent)
                    LabeledContent("处理方式", value: model.configuration.automaticTranscription ? "保存录音并生成文字" : "仅保存录音")
                    Button("重新打开三步设置") { model.beginSetup() }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
                    if model.busy { Text("当前任务完成或暂停后，即可重新设置。").font(.caption).foregroundStyle(.secondary) }
                }.padding(25).background(.white, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("中文识别", systemImage: "text.bubble").font(.callout.weight(.semibold))
                        Spacer()
                        Text(model.speechReady ? "已经准备好" : model.speechStatus).font(.callout).foregroundStyle(model.speechReady ? MemoStyle.green : .secondary)
                    }
                    Text("本机识别无需上传录音。首次准备需要联网。").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(model.installingModel ? "正在准备…" : "准备中文识别") { model.installModel() }.buttonStyle(SecondaryButtonStyle()).disabled(model.installingModel)
                        Button("重新检查") { Task { await model.checkSpeech() } }.buttonStyle(.plain).foregroundStyle(MemoStyle.green)
                    }
                }.padding(25).background(.white, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("登录 Mac 时自动打开引导版", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    Text("开启后，登录 Mac 即可等待设备接入。建议将应用放进“应用程序”文件夹后开启。").font(.caption).foregroundStyle(.secondary)
                }.padding(25).background(.white, in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 13) {
                    Label("再次连接时，只处理新增或变化的录音", systemImage: "arrow.triangle.2.circlepath").font(.callout.weight(.semibold))
                    Text("平时快速检查文件变化。完整检查会重新读取全部录音内容，耗时更长。").font(.caption).foregroundStyle(.secondary)
                    Button("完整检查录音来源") { model.scanMountedVolumes(fullVerification: true) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(model.busy || model.paused)
                    if model.paused { Text("继续整理后，就可以完整检查录音来源。").font(.caption).foregroundStyle(.secondary) }
                }.padding(25).background(.white, in: RoundedRectangle(cornerRadius: 18))
                Button { model.section = "advanced" } label: {
                    HStack { Label("高级设置", systemImage: "gearshape"); Spacer(); Text("多设备、云端转写、配置文件").foregroundStyle(.secondary); Image(systemName: "chevron.right") }.font(.callout)
                }.buttonStyle(.plain).padding(.horizontal, 4)
            }.padding(32)
        }
    }
}
struct GuidedEventPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("运行记录").font(.system(size: 30, weight: .bold))
            Text("了解导入结果，查找未能完成的原因。").foregroundStyle(.secondary)
            List(model.snapshot.events.reversed()) { event in
                VStack(alignment: .leading, spacing: 8) {
                    Label(event.message, systemImage: event.isError ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(event.isError ? .orange : .primary).textSelection(.enabled)
                    Text(event.date.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 9)
            }.listStyle(.inset)
        }.padding(30)
    }
}
