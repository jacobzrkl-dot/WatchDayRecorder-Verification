import SwiftUI

struct PhoneSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var receiver: PhoneConnectivityReceiver
    var onContinue: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .font(.system(size: 48)).foregroundStyle(.red)
                    Text("从手表开始，\n在手机安心保存。")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("不用 iCloud。手表独立录音，手机接收后可以连播、合并导出和整理。")
                        .foregroundStyle(.secondary)
                    if !receiver.supportsWatchConnectivity {
                        Text(receiver.connectionText).font(.callout).foregroundStyle(.orange)
                    }
                    if receiver.setupState != .ready {
                        Text(receiver.setupState.guidance).font(.callout).foregroundStyle(.orange)
                    }
                    checklistRow(
                        number: "1", title: "配对 Apple Watch",
                        detail: receiver.isActivated ? (receiver.isPaired ? "已检测到配对手表" : "请先用 iPhone 的 Watch App 完成配对") : receiver.setupState.title,
                        complete: receiver.isActivated && receiver.isPaired
                    )
                    checklistRow(
                        number: "2", title: "安装并打开手表端",
                        detail: receiver.isActivated ? (receiver.isWatchAppInstalled ? "已检测到手表端安装" : "请在 Watch App 中安装“全天录音”，然后在手表打开") : "连接启用后会检查安装状态",
                        complete: receiver.isActivated && receiver.isWatchAppInstalled
                    )
                    checklistRow(
                        number: "3", title: "在手表授权并试录",
                        detail: "第一次点击录音时允许麦克风权限。先录 30 秒并停止，确认手机收到且能播放。手机无法代替手表授予麦克风权限。",
                        complete: false
                    )
                    Text("录音期间每 10 分钟自动封存一段；短录音点击停止后才会传输。手机不在身边时，分段保留在手表等待连接。")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("请先完成短录音、离线回传和长时间测试，再用于重要的全天录音。")
                        .font(.caption).foregroundStyle(.orange)
                    Button {
                        onContinue()
                        dismiss()
                    } label: {
                        Text("已了解，进入录音库").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    Button("重新检查设备状态") { receiver.refreshDeviceStatus() }
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .navigationTitle("首次使用")
            .navigationBarTitleDisplayMode(.inline)
            .task { receiver.refreshDeviceStatus() }
        }
        .preferredColorScheme(.dark)
    }

    private func checklistRow(number: String, title: String, detail: String, complete: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.headline).frame(width: 32, height: 32)
                .background(complete ? Color.green.opacity(0.18) : Color.white.opacity(0.09), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle")
                    .font(.headline).foregroundStyle(complete ? .green : .white)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
