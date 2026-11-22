import Foundation

enum CompanionSetupState: Equatable {
    case unsupported, activating, failed, unpaired, missingApp, ready

    static func resolve(supported: Bool, activated: Bool, failed: Bool, paired: Bool, installed: Bool) -> Self {
        if !supported { return .unsupported }
        if !activated { return failed ? .failed : .activating }
        if !paired { return .unpaired }
        return installed ? .ready : .missingApp
    }

    var title: String {
        switch self {
        case .unsupported: "当前环境不支持手表连接"
        case .activating: "正在启用手表连接"
        case .failed: "手表连接启用失败"
        case .unpaired: "尚未配对 Apple Watch"
        case .missingApp: "手表端尚未安装"
        case .ready: "手表同步通道已就绪"
        }
    }

    var badge: String {
        switch self {
        case .unsupported: "不可用"
        case .activating: "连接中"
        case .failed: "连接失败"
        case .unpaired: "待配对"
        case .missingApp: "待安装"
        case .ready: "通道就绪"
        }
    }

    var guidance: String {
        switch self {
        case .unsupported: "请在支持 Apple Watch 的 iPhone 真机使用；本地录音仍可查看。"
        case .activating: "等待系统启用连接；本地录音可先播放和导出。"
        case .failed: "点按重试同步，重新启用连接。"
        case .unpaired: "打开 iPhone 的 Watch App 完成配对，再返回这里。"
        case .missingApp: "在 Watch App 中安装“全天录音”，然后在手表打开一次。"
        case .ready: "传输由系统安排；通道就绪不代表手表当前在线或整场已收齐。"
        }
    }
}
