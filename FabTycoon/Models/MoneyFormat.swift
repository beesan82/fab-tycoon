import Foundation

/// 円・個数・時間の表示用フォーマッタ
enum MoneyFormat {
    private static func makeFormatter(maxFractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.roundingMode = .halfUp
        return formatter
    }

    private static let okuFormatter = makeFormatter(maxFractionDigits: 2)
    private static let manFormatter = makeFormatter(maxFractionDigits: 1)
    private static let integerFormatter = makeFormatter(maxFractionDigits: 0)

    private static func string(_ formatter: NumberFormatter, _ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 1億以上→「12.34億円」、1万以上→「123.4万円」、未満→「999円」。負数対応。
    static func yen(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        let body: String
        // 丸めで単位が繰り上がる境界（例：9999.96万円→1億円）も考慮する
        if magnitude >= 100_000_000 || (magnitude / 10_000 * 10).rounded() / 10 >= 10_000 {
            body = string(okuFormatter, magnitude / 100_000_000) + "億円"
        } else if magnitude.rounded() >= 10_000 {
            body = string(manFormatter, magnitude / 10_000) + "万円"
        } else {
            body = string(integerFormatter, magnitude) + "円"
        }
        if value < 0 && body != "0円" {
            return "-" + body
        }
        return body
    }

    /// 正の値に「+」を付ける（収入表示用）
    static func signedYen(_ value: Double) -> String {
        let text = yen(value)
        return value > 0 && text != "0円" ? "+" + text : text
    }

    /// チップ個数などの整数表示（3桁区切り、小数切り捨て）
    static func count(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return string(integerFormatter, value.rounded(.towardZero))
    }

    static func decimal(_ value: Double, digits: Int = 2) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(digits)f", value)
    }

    static func percent(_ ratio: Double, digits: Int = 1) -> String {
        guard ratio.isFinite else { return "—" }
        return String(format: "%.\(digits)f%%", ratio * 100)
    }

    /// 「1時間23分」「4分05秒」「12秒」
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let total = Int(max(0, seconds))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return "\(hours)時間\(minutes)分"
        }
        if minutes > 0 {
            return String(format: "%d分%02d秒", minutes, secs)
        }
        return "\(secs)秒"
    }
}
