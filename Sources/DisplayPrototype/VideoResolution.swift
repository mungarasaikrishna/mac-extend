enum VideoResolution: String, CaseIterable {
    case standard = "1440p"
    case native4K = "4k"

    var width: Int { self == .native4K ? 4096 : 2560 }
    var height: Int { self == .native4K ? 2304 : 1440 }
    var bitrate: Int { self == .native4K ? 36_000_000 : 16_000_000 }

    var title: String {
        switch self {
        case .standard: return "1440p · 2560 × 1440"
        case .native4K: return "Native 4K · 4096 × 2304"
        }
    }
}
