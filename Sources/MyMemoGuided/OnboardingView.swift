import SwiftUI
import MyMemoExperience

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    private var heading: String {
        switch model.step {
        case .source: "把录音笔接到这台 Mac"
        case .destination: "这些录音，保存到哪里？"
        case .ready: "准备好，就可以开始了"
        }
    }
    private var introduction: String {
        switch model.step {
        case .source: "连接后，在下面选中你的设备。以后再接入，就会自动识别。"
        case .destination: "选一个好找的位置。原始录音和生成的文字稿都会放在这里。"
        case .ready: "确认下面的选择。完成这一步后，MyMemo 就会按你的设置整理录音。"
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        Text("第 \(model.step.rawValue + 1) 步，共 3 步").font(.callout.weight(.medium)).foregroundStyle(MemoStyle.green)
                        VStack(alignment: .leading, spacing: 12) {
                            Text(heading).font(.system(size: 31, weight: .bold))
                            Text(introduction).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(4)
                        }
                        switch model.step {
                        case .source: SourceStep(model: model)
                        case .destination: DestinationStep(model: model)
                        case .ready: ReadyStep(model: model)
                        }
                    }.frame(maxWidth: 640, alignment: .leading).padding(.horizontal, 40).padding(.vertical, 36)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                footer
            }.background(MemoStyle.canvas)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandMark().padding(.bottom, 54)
            Text("简单三步，就能用起来").font(.callout.weight(.semibold)).padding(.bottom, 26)
            ForEach(SetupStep.allCases, id: \.rawValue) { step in
                HStack(alignment: .top, spacing: 13) {
                    ZStack {
                        Circle().fill(step.rawValue <= model.step.rawValue ? MemoStyle.green : .white).frame(width: 32, height: 32)
                        if step.rawValue < model.step.rawValue { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                        else { Text("\(step.rawValue + 1)").font(.callout.bold()).foregroundStyle(step == model.step ? .white : .secondary) }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(step.title).font(.system(size: 15, weight: step == model.step ? .bold : .medium))
                        Text(step == .source ? "选中你的录音笔" : step == .destination ? "录音和文字存放处" : "开始自动整理")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 2)
                }.opacity(step.rawValue > model.step.rawValue ? 0.65 : 1)
                if step != .ready { Rectangle().fill(MemoStyle.green.opacity(0.16)).frame(width: 1, height: 29).padding(.leading, 16).padding(.vertical, 6) }
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 12) {
                Label("原始录音保留", systemImage: "checkmark.shield")
                Label("视频自动跳过", systemImage: "video.slash")
                Label("中文识别在本机完成", systemImage: "laptopcomputer")
            }.font(.caption).foregroundStyle(MemoStyle.green)
            Divider().padding(.top, 20)
            AuthorInfoView().padding(.top, 12)
            Text("MyMemo · 0.3.0").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 12)
        }.padding(28).frame(width: 258, alignment: .leading).frame(maxHeight: .infinity)
            .background(MemoStyle.pale.opacity(0.72))
    }
    private var footer: some View {
        HStack {
            if model.step != .source {
                Button { model.previousStep() } label: { Label("上一步", systemImage: "arrow.left") }.buttonStyle(.plain)
            } else if model.preferences.completed {
                Button("返回首页") { model.cancelSetup() }.buttonStyle(.plain)
            }
            Spacer()
            if model.finishingSetup { ProgressView().controlSize(.small) }
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if model.step == .ready { model.finishSetup() } else { model.nextStep() }
                }
            } label: {
                HStack(spacing: 12) {
                    Text(model.step == .source ? "下一步：选择保存位置" : model.step == .destination ? "下一步：确认设置" : model.draft.source == .later ? "完成设置，稍后连接" : "开始整理录音")
                    Image(systemName: "arrow.right")
                }
            }.buttonStyle(PrimaryButtonStyle())
                .disabled(!model.draft.canAdvance(from: model.step) || model.finishingSetup || (model.step == .ready && model.draft.transcribe && !model.speechReady))
                .keyboardShortcut(.defaultAction)
        }.padding(.horizontal, 40).padding(.vertical, 21)
            .background(.white).overlay(alignment: .top) { Rectangle().fill(MemoStyle.line).frame(height: 1) }
    }
}

private struct SourceStep: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if model.volumes.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "externaldrive.badge.plus").font(.system(size: 46, weight: .light)).foregroundStyle(MemoStyle.green)
                    Text("还没看到录音设备").font(.title3.weight(.semibold))
                    Text("确认设备已开机，并使用能传输数据的 USB 线连接。\n能在 Finder 中看到的磁盘，会显示在这里。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                    Button("重新检测") { model.refreshVolumes() }.buttonStyle(SecondaryButtonStyle())
                }.padding(26).frame(maxWidth: .infinity).background(.white, in: RoundedRectangle(cornerRadius: 18))
            } else {
                HStack { Text("发现 \(model.volumes.count) 个已连接的设备").font(.callout.weight(.medium)); Spacer(); Button("重新检测") { model.refreshVolumes() }.buttonStyle(.plain).foregroundStyle(MemoStyle.green) }
                ForEach(model.volumes) { volume in
                    ChoiceCard(symbol: "externaldrive", title: volume.name, subtitle: "已连接到这台 Mac · 点击选择",
                        selected: model.draft.source == .device && model.draft.devicePath == volume.url.path) { model.selectDevice(volume) }
                }
            }
            if model.draft.source == .device && !model.draft.deviceName.isEmpty && !model.selectedDeviceConnected {
                Label("已选设备暂时断开：\(model.draft.deviceName)。可以继续设置，完成后再接入。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("录音笔不在身边？也可以这样开始").font(.callout).foregroundStyle(.secondary).padding(.top, 10)
            ChoiceCard(symbol: "folder", title: model.draft.sourceFolder.isEmpty ? "选择电脑上的录音文件夹" : URL(fileURLWithPath: model.draft.sourceFolder).lastPathComponent,
                subtitle: model.draft.sourceFolder.isEmpty ? "整理已经拷贝到电脑上的录音" : "将从这个文件夹导入 · 点击可以更换",
                selected: model.draft.source == .folder) { model.chooseSourceFolder() }
            Button {
                model.draft.source = .later
            } label: {
                HStack { Image(systemName: model.draft.source == .later ? "checkmark.circle.fill" : "clock"); Text("稍后连接设备，先完成其余设置"); Spacer() }
                    .font(.callout).foregroundStyle(model.draft.source == .later ? MemoStyle.green : .secondary).padding(.vertical, 9)
            }.buttonStyle(.plain)
        }
    }
}

private struct DestinationStep: View {
    @ObservedObject var model: AppModel
    private var recommended: String { SetupDraft().destination }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChoiceCard(symbol: "folder.fill", title: "MyMemo 录音", subtitle: "放在这台 Mac 的“音乐”文件夹中，方便找到。", selected: model.draft.destination == recommended, badge: "推荐") {
                model.draft.destination = recommended
            }
            ChoiceCard(symbol: "folder.badge.gearshape", title: model.draft.destination == recommended ? "选择其他文件夹" : URL(fileURLWithPath: model.draft.destination).lastPathComponent,
                subtitle: model.draft.destination == recommended ? "使用你习惯的保存位置" : "已选择自定义位置 · 点击可以更换",
                selected: model.draft.destination != recommended) { model.chooseDestination() }
            VStack(alignment: .leading, spacing: 17) {
                Text("保存以后，你会找到这些内容").font(.callout.weight(.semibold))
                HStack(spacing: 16) {
                    outputItem("waveform", "原始录音", "可以随时回听")
                    Image(systemName: "plus").foregroundStyle(.tertiary)
                    outputItem("doc.text", "完整文字稿", "选择转写后生成")
                }
                Text("按设备和日期自动整理，相同录音不会重复导入。").font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 16))
            DisclosureGroup("查看完整保存位置") { Text(model.draft.destination).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7) }.font(.caption).foregroundStyle(.secondary)
            if !model.draft.canAdvance(from: .destination) {
                Label("这个位置不能用来保存副本，请另选电脑上的文件夹。", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
        }
    }
    private func outputItem(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(MemoStyle.green)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.callout.weight(.medium)); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReadyStep: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ChoiceCard(symbol: "waveform.and.magnifyingglass", title: "保存录音，同时生成文字", subtitle: "中文识别在本机完成，录音不需要上传。", selected: model.draft.transcribe, badge: "推荐") { model.draft.transcribe = true }
            ChoiceCard(symbol: "tray.and.arrow.down", title: "这次只保存录音", subtitle: "以后需要时，还可以为这些录音生成文字。", selected: !model.draft.transcribe) { model.draft.transcribe = false }
            if model.draft.transcribe {
                HStack(spacing: 12) {
                    if model.installingModel || model.checkingSpeech { ProgressView().controlSize(.small) }
                    else { Image(systemName: model.speechReady ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(model.speechReady ? MemoStyle.green : .orange) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.speechReady ? "中文识别已准备好" : model.speechStatus).font(.callout.weight(.medium))
                        if !model.speechReady { Text("首次准备需要联网，之后可以离线使用。").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !model.speechReady {
                        Button(model.installingModel ? "准备中…" : "准备中文识别") { model.installModel() }.buttonStyle(SecondaryButtonStyle()).disabled(model.installingModel || model.checkingSpeech)
                    }
                }.padding(15).background(.white, in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("确认你的选择").font(.callout.weight(.semibold))
                summary("录音来自", model.draft.source == .device ? model.draft.deviceName : model.draft.source == .folder ? URL(fileURLWithPath: model.draft.sourceFolder).lastPathComponent : "稍后连接设备")
                summary("保存到", URL(fileURLWithPath: model.draft.destination).lastPathComponent)
                summary("完成后得到", model.draft.transcribe ? "录音文件 + 中文文字稿" : "录音文件")
            }.padding(20).background(MemoStyle.pale.opacity(0.6), in: RoundedRectangle(cornerRadius: 16)).padding(.top, 5)
            Text(model.draft.source == .later ? "完成后可以随时添加录音设备。" : "点击开始后，会复制并校验纯音频，原文件保留。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func summary(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading); Text(value).fontWeight(.medium).lineLimit(2); Spacer(minLength: 0) }.font(.callout)
    }
}
