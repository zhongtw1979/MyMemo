import SwiftUI

enum MemoStyle {
    static let green = Color(red: 0.10, green: 0.43, blue: 0.34)
    static let pale = Color(red: 0.91, green: 0.96, blue: 0.92)
    static let canvas = Color(red: 0.975, green: 0.978, blue: 0.965)
    static let line = Color.black.opacity(0.07)
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 24).padding(.vertical, 14)
            .foregroundStyle(enabled ? .white : Color.secondary)
            .background(enabled ? MemoStyle.green.opacity(configuration.isPressed ? 0.8 : 1) : Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(MemoStyle.green)
            .background(.white.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(MemoStyle.line))
    }
}
struct ChoiceCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let selected: Bool
    var badge: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 24, weight: .regular))
                    .foregroundStyle(MemoStyle.green).frame(width: 52, height: 52)
                    .background(selected ? Color.white : MemoStyle.pale.opacity(0.7), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.system(size: 17, weight: .semibold))
                        if let badge { Text(badge).font(.caption.weight(.medium)).foregroundStyle(MemoStyle.green).padding(.horizontal, 7).padding(.vertical, 3).background(.white, in: Capsule()) }
                    }
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(selected ? MemoStyle.green : Color.secondary.opacity(0.35))
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? MemoStyle.pale : .white, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? MemoStyle.green.opacity(0.65) : MemoStyle.line, lineWidth: selected ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
        .accessibilityLabel(title + (selected ? "，已选择" : ""))
    }
}
struct BrandMark: View {
    var compact = false
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(MemoStyle.green.gradient, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("MyMemo").font(.system(size: 21, weight: .bold, design: .rounded))
                Text(compact ? "录音整理" : "让录音整理更省心").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AuthorInfoView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("作者：钟天炜")
            Text("联系方式：微信 zhongtw")
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
