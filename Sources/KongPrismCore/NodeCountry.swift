import Foundation

/// Which country a node name says it is in ("中国香港-…" → HK, "🇩🇪 …" → DE, "澳大利亚-…" → AU).
public enum NodeCountry {
    static let names: [(String, String)] = [
        ("香港", "HK"), ("台湾", "TW"), ("臺灣", "TW"), ("澳门", "MO"), ("日本", "JP"), ("韩国", "KR"), ("韓國", "KR"),
        ("新加坡", "SG"), ("美国", "US"), ("美國", "US"), ("英国", "GB"), ("德国", "DE"), ("法国", "FR"), ("荷兰", "NL"),
        ("加拿大", "CA"), ("澳大利亚", "AU"), ("澳洲", "AU"), ("俄罗斯", "RU"), ("印度", "IN"), ("马来西亚", "MY"),
        ("泰国", "TH"), ("越南", "VN"), ("菲律宾", "PH"), ("印尼", "ID"), ("土耳其", "TR"), ("阿联酋", "AE"),
        ("阿根廷", "AR"), ("巴西", "BR"),
    ]

    public static func code(for name: String) -> String? {
        // A flag emoji: two regional indicator symbols.
        let scalars = Array(name.unicodeScalars)
        for index in scalars.indices.dropLast() {
            let a = scalars[index].value, b = scalars[index + 1].value
            if (0x1F1E6...0x1F1FF).contains(a), (0x1F1E6...0x1F1FF).contains(b) {
                guard let first = UnicodeScalar(a - 0x1F1E6 + 65), let second = UnicodeScalar(b - 0x1F1E6 + 65) else { continue }
                return String(Character(first)) + String(Character(second))
            }
        }
        if let region = Region.of(name) { return region.code }
        return names.first { name.contains($0.0) }?.1
    }
}
