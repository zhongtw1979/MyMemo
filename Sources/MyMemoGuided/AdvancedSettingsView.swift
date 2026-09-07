import SwiftUI
import AppKit
import MyMemoCore

struct AdvancedSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft: AppConfiguration
    @State private var deviceName = ""

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("高级设置").font(.largeTitle.bold())
                    Text("更多设备与转写选项。日常使用可以直接在首页操作。").foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存设置") { model.saveConfiguration(draft) }.buttonStyle(.borderedProminent)
                    .disabled(model.startupError != nil)
            }.padding(.horizontal, 24).padding(.top, 24)
            Form {
                Section("录音设备名单") {
                    ForEach($draft.devices) { $device in
                        HStack {
                            Toggle("启用", isOn: $device.enabled).labelsHidden().help("启用此设备")
                            TextField("Finder 中的名称", text: $device.name)
                            TextField("卷 UUID（可选）", text: Binding(get: { device.volumeUUID ?? "" }, set: { device.volumeUUID = $0.isEmpty ? nil : $0 }))
                                .font(.caption).frame(maxWidth: 260)
                            Button(role: .destructive) { draft.devices.removeAll { $0.id == device.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("移除此设备")
                        }
                    }
                    HStack {
                        TextField("输入设备名称，例如 RECORDER", text: $deviceName).onSubmit(addDevice)
                        Button("添加名称", action: addDevice).disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !model.volumes.isEmpty {
                        ForEach(model.volumes) { volume in
                            HStack {
                                Label(volume.name, systemImage: "externaldrive")
                                Text("已连接").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("加入名单") {
                                    if !draft.devices.contains(where: { $0.name == volume.name }) { draft.devices.append(DeviceRule(name: volume.name)) }
                                }.disabled(draft.devices.contains { $0.name == volume.name })
                            }
                        }
                    }
                    Text("完整名称匹配，不使用模糊匹配。填写卷 UUID 后，还会核对磁盘身份。当前已连接设备：\(model.volumes.count) 个。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("保存位置") {
                    HStack {
                        Text(draft.destinationPath.isEmpty ? "尚未选择保存目录" : draft.destinationPath)
                            .foregroundStyle(draft.destinationPath.isEmpty ? .secondary : .primary).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("选择目录…") { chooseDestination() }
                        if !draft.destinationPath.isEmpty {
                            Button("打开") { NSWorkspace.shared.open(URL(fileURLWithPath: draft.destinationPath)) }
                        }
                    }
                    Text("录音按“设备 / 导入日期”保存。相同内容只导入一次，原设备中的文件保持不变。").font(.caption).foregroundStyle(.secondary)
                    Text("只导入纯音频：复制前检查音轨和视频轨道，视频与无法确认的文件会跳过。MP4 只有不含视频轨道时才会导入。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("设备接入时自动导入", isOn: $draft.automaticImport)
                    Toggle("导入后自动转成文字", isOn: $draft.automaticTranscription)
                }

                Section("语音转文字") {
                    Picker("转写方式", selection: $draft.provider) {
                        ForEach(TranscriptionProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
                    }
                    if draft.provider == .apple {
                        Picker("录音语言", selection: $draft.localeIdentifier) {
                            Text("普通话（简体中文）").tag("zh-CN")
                            Text("英语（美国）").tag("en-US")
                            Text("粤语（香港）").tag("yue-CN")
                            Text("日语").tag("ja-JP")
                        }
                        HStack {
                            Text(model.speechStatus).foregroundStyle(.secondary)
                            Spacer()
                            Button("检测") { model.saveConfiguration(draft); Task { await model.checkSpeech() } }
                            Button(model.installingModel ? "正在准备…" : "下载语言模型") {
                                model.saveConfiguration(draft); model.installModel()
                            }.disabled(model.installingModel)
                        }
                        Text("录音在本机识别。首次使用需要联网下载苹果语言模型，之后可离线转写。语言是否可用以本机检测为准。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("使用本机已有的火山引擎转写脚本，音频会发送到火山引擎，费用按你的服务方案计算。")
                            .font(.callout).foregroundStyle(.secondary)
                        TextField("Python 路径", text: $draft.pythonPath)
                        TextField("转写脚本路径", text: $draft.volcScriptPath)
                        Toggle("允许将导入的录音发送到火山引擎转写", isOn: $draft.cloudConsent)
                        Text("密钥由脚本从 ~/.config/volc/agent-plan.env 读取，不写入 MyMemo 配置。此接口通常按录音时长发送音频，长录音需要较长时间。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("应用与配置文件") {
                    Toggle("登录 Mac 时启动 MyMemo", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                    HStack {
                        Button("载入配置文件…") { model.importConfiguration() }
                        Button("导出已保存的配置…") { model.exportConfiguration() }
                        Button("显示运行数据") { NSWorkspace.shared.open(model.dataDirectory) }
                    }
                    Text("所有设置保存为 config.json。手动修改该文件后重新打开应用即可生效。关闭窗口会继续监听；从菜单栏退出后停止处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
        .onChange(of: model.configuration) { _, value in draft = value }
    }

    private func addDevice() {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !draft.devices.contains(where: { $0.name == name }) else { return }
        draft.devices.append(DeviceRule(name: name)); deviceName = ""
    }
    private func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "保存到这里"
        panel.message = "选择 Mac 上保存录音和文字稿的文件夹。"
        if panel.runModal() == .OK, let url = panel.url { draft.destinationPath = url.path }
    }
}
