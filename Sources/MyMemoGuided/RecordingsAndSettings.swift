import SwiftUI
import AppKit
import MyMemoCore

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
