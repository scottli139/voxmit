import Foundation

/// HF 模型仓库端点（需求文档 §4.2.3 下载策略）：huggingface.co 在部分网络不可达，
/// 自动回退 hf-mirror.com 镜像（真机验收实测：官方超时、镜像可用）
enum ModelRepoEndpoint: String, Sendable, CaseIterable, Equatable {
    case huggingface = "https://huggingface.co"
    case hfMirror = "https://hf-mirror.com"

    var displayName: String {
        switch self {
        case .huggingface: return "huggingface.co（官方）"
        case .hfMirror: return "hf-mirror.com（镜像）"
        }
    }
}

/// 端点尝试顺序决策（纯逻辑可单测）：设置键 asr.modelRepoEndpoint
/// - unset / "auto"（默认）：官方优先，失败后回退镜像
/// - "huggingface" / "hf-mirror"：强制指定，只试该端点
/// - 未知值：按 auto 处理
enum ModelRepoEndpointResolver {
    static func attemptOrder(setting: String?) -> [ModelRepoEndpoint] {
        switch setting {
        case "huggingface":
            return [.huggingface]
        case "hf-mirror":
            return [.hfMirror]
        default:
            return [.huggingface, .hfMirror]
        }
    }
}

/// 单端点下载失败明细
struct EndpointFailure: Sendable, Equatable {
    let endpoint: String
    let reason: String
}

enum ModelDownloadError: LocalizedError, Equatable {
    /// 链上端点全部失败（错误信息注明各端点与原因）
    case allEndpointsFailed([EndpointFailure])

    var errorDescription: String? {
        guard case .allEndpointsFailed(let failures) = self else { return nil }
        let detail = failures.map { "\($0.endpoint)：\($0.reason)" }.joined(separator: "；")
        if failures.count > 1 {
            return "官方与镜像端点均下载失败（\(detail)）"
        }
        return "模型下载失败（\(detail)）"
    }
}
