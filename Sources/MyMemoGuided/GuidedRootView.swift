import SwiftUI
import AppKit
import MyMemoCore

struct GuidedRootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Group {
            if let error = model.startupError {
                ContentUnavailableView {
                    Label("暂时无法打开录音库", systemImage: "exclamationmark.folder")
                } description: { Text(error).textSelection(.enabled) } actions: {
                    Button("打开运行数据文件夹") { NSWorkspace.shared.open(model.dataDirectory) }
                }
            } else if model.showSetup { OnboardingView(model: model) }
            else { workspace }
        }.alert("需要你留意一下", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    private var workspace: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                BrandMark(compact: true).padding(.vertical, 26).padding(.horizontal, 13)
                navigation("home", "首页", "house")
                navigation("library", "我的录音", "waveform")
                navigation("settings", "设置", "slider.horizontal.3")
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.paused ? "自动整理已暂停" : "自动整理已开启", systemImage: model.paused ? "pause.circle" : "checkmark.circle.fill")
                        .foregroundStyle(model.paused ? .orange : MemoStyle.green).font(.caption.weight(.medium))
                    Button(model.paused ? "继续整理" : "暂停") { model.togglePause() }.buttonStyle(SecondaryButtonStyle())
                    Text("关闭窗口后，仍可从菜单栏找到 MyMemo。").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
                    Button("查看运行记录") { model.section = "events" }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    Divider()
                    AuthorInfoView()
                }.padding(13).padding(.bottom, 13)
            }.padding(.horizontal, 12).frame(width: 208).background(MemoStyle.pale.opacity(0.65))
            VStack(spacing: 0) {
                switch model.section {
                case "library": GuidedRecordingPage(model: model)
                case "settings": FriendlySettingsView(model: model)
                case "advanced":
                    HStack { Button("返回设置") { model.section = "settings" }.buttonStyle(.plain); Spacer() }.padding(.horizontal, 24).padding(.top, 16)
                    AdvancedSettingsView(model: model)
                case "events": GuidedEventPage(model: model)
                default: HomeView(model: model)
                }
                HStack(spacing: 9) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Circle().fill(model.paused ? .orange : MemoStyle.green).frame(width: 7, height: 7) }
                    Text(model.activity).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if model.busy { Text("请保持 Mac 唤醒").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 28).padding(.vertical, 12).background(.white)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(MemoStyle.canvas)
        }
    }
    private func navigation(_ section: String, _ title: String, _ icon: String) -> some View {
        Button { model.section = section } label: {
            Label(title, systemImage: icon).font(.system(size: 15, weight: model.section == section ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .foregroundStyle(model.section == section ? MemoStyle.green : .primary)
                .background(model.section == section ? .white : .clear, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
}

private struct HomeView: View {
    @ObservedObject var model: AppModel
    private var heroTitle: String {
        if model.loadingLibrary { return "正在读取录音清单" }
        if model.busy { return "正在整理你的录音" }
        if model.paused { return "需要时，继续整理就好" }
        if let result = model.lastImport, result.failed > 0 { return "有些录音还没保存成功" }
        if !model.failed.isEmpty { return "录音已保存，有几条需要重试" }
        if let result = model.lastImport, result.imported == 0 && result.skipped > 0 { return "已经是最新的了" }
        if let result = model.lastImport, result.imported == 0 && result.skipped == 0 { return "这次没有找到可导入的录音" }
        if !model.completed.isEmpty { return "录音和文字稿，都在这里了" }
        if model.configuration.devices.isEmpty { return "准备好了，选一份录音开始" }
        if model.matchingVolumes.isEmpty { return "接上录音笔，就可以开始" }
        return "设备已连接，可以整理录音了"
    }
    private var heroDetail: String {
        if model.loadingLibrary { return "清单载入后即可查看已有文字稿，无需等待音频扫描。" }
        if model.busy { return model.activity }
        if model.paused { return "已经保存的录音会保留。点击继续后，按当前设置接着处理。" }
        if let result = model.lastImport, result.failed > 0 { return "这次有 \(result.failed) 个文件未能保存。可以查看运行记录，重新连接后再检查。" }
        if !model.failed.isEmpty { return "原始录音仍在电脑上，可以查看原因并重新生成文字。" }
        if let result = model.lastImport, result.imported == 0 && result.skipped > 0 {
            return "已有 \(result.skipped) 份录音，无需重复导入。下次接入时，会继续检查新增或变化的文件。"
        }
        if let result = model.lastImport, result.imported == 0 && result.skipped == 0 { return "只导入纯音频，视频和无法识别的文件会跳过。可以换一个录音文件夹试试。" }
        if !model.completed.isEmpty { return "打开文字稿即可阅读，也可以回到原始录音核对。" }
        return model.configuration.devices.isEmpty ? "你可以连接一台录音设备，也可以从电脑上的文件夹导入。" : "已记住：\(model.configuration.devices.map(\.name).joined(separator: "、"))。再次接入时会自动识别。"
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("我的录音空间").font(.system(size: 30, weight: .bold))
                        Text("录音自动归档，文字稿随时可查。").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.chooseImportFolder() } label: { Label("导入文件夹", systemImage: "folder.badge.plus") }.buttonStyle(SecondaryButtonStyle())
                }
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 15) {
                        Label(model.busy ? "正在处理" : "当前状态", systemImage: model.busy ? "waveform" : "circle.fill").font(.caption.weight(.medium)).foregroundStyle(MemoStyle.green)
                        Text(heroTitle).font(.system(size: 24, weight: .semibold))
                        Text(heroDetail).font(.callout).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        heroAction.padding(.top, 3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: model.busy ? "waveform" : !model.completed.isEmpty ? "doc.text.below.ecg" : "externaldrive.badge.checkmark")
                        .font(.system(size: 64, weight: .ultraLight)).foregroundStyle(MemoStyle.green.opacity(0.65)).frame(width: 110)
                }.padding(28).frame(maxWidth: .infinity, alignment: .leading).background(MemoStyle.pale, in: RoundedRectangle(cornerRadius: 22))
                HStack(spacing: 14) {
                    count("已保存录音", model.recordings.count, "waveform")
                    count("已生成文字稿", model.completed.count, "doc.text")
                    count("需要重试", model.failed.count, "arrow.clockwise")
                }
                HStack { Text("最近的录音").font(.title3.weight(.semibold)); Spacer(); Button("查看全部") { model.section = "library" }.buttonStyle(.plain).foregroundStyle(MemoStyle.green) }
                if model.recordings.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        Text("第一份录音会出现在这里").font(.callout.weight(.medium))
                        Text("导入完成后，可以打开录音、阅读文字稿，或查看处理进度。").font(.caption).foregroundStyle(.secondary)
                    }.padding(30).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.recordings.suffix(4).reversed())) { job in
                            Button { model.selectedID = job.id; model.section = "library" } label: { GuidedRecordingRow(job: job) }.buttonStyle(.plain)
                            if job.id != model.recordings.suffix(4).first?.id { Divider().padding(.leading, 64) }
                        }
                    }.background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
                HStack {
                    Label(URL(fileURLWithPath: model.configuration.destinationPath).lastPathComponent, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("打开保存文件夹") { NSWorkspace.shared.open(URL(fileURLWithPath: model.configuration.destinationPath)) }.buttonStyle(.plain).font(.caption).foregroundStyle(MemoStyle.green)
                }
            }.padding(32)
        }
    }
    @ViewBuilder private var heroAction: some View {
        if model.busy { Button("当前录音完成后暂停") { model.togglePause() }.buttonStyle(SecondaryButtonStyle()) }
        else if model.paused { Button("继续整理录音") { model.togglePause() }.buttonStyle(PrimaryButtonStyle()) }
        else if let result = model.lastImport, result.failed > 0 { Button("查看导入情况") { model.section = "events" }.buttonStyle(PrimaryButtonStyle()) }
        else if !model.failed.isEmpty { Button("查看需要重试的录音") { model.section = "library" }.buttonStyle(PrimaryButtonStyle()) }
        else if let latest = model.completed.last, let path = latest.transcriptPath { Button("打开最新文字稿") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(PrimaryButtonStyle()) }
        else if model.configuration.devices.isEmpty { Button("连接录音设备") { model.beginSetup() }.buttonStyle(PrimaryButtonStyle()) }
        else { Button("检查已连接的设备") { model.scanMountedVolumes() }.buttonStyle(PrimaryButtonStyle()) }
    }
    private func count(_ title: String, _ value: Int, _ icon: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 11) { Text(title).font(.callout).foregroundStyle(.secondary); Text(value.formatted()).font(.system(size: 30, weight: .semibold, design: .rounded)) }
            Spacer(); Image(systemName: icon).font(.title2).foregroundStyle(MemoStyle.green.opacity(0.65))
        }.padding(20).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct GuidedRecordingRow: View {
    let job: RecordingJob
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.status == .done ? "doc.text" : "waveform").font(.title3).foregroundStyle(MemoStyle.green)
                .frame(width: 38, height: 40).background(MemoStyle.pale, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text(job.originalName).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(job.deviceName) · \(job.importedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(job.status == .done ? "文字已生成" : job.status == .queued ? "录音已保存" : job.status.title)
                .font(.caption).foregroundStyle(job.status == .failed ? .orange : MemoStyle.green)
        }.padding(16).contentShape(Rectangle())
    }
}
