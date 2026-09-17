import Foundation

enum Naming {
    static let tokens = ["project", "name", "format", "size", "version", "date", "n"]

    static func clean(_ stem: String, junk: Set<String>) -> String {
        var s = stem
        s = s.replacingOccurrences(of: #"\s*\(\d+\)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\bcopy\s*\d+\b"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        let words = words(s).filter { w in
            !junk.contains(w)
                && w.range(of: #"^v\d{1,3}$"#, options: .regularExpression) == nil
                && w.range(of: #"^\d{2,5}x\d{2,5}$"#, options: .regularExpression) == nil
        }
        let result = words.joined(separator: "-")
        return result.isEmpty ? slug(stem) : result
    }

    static func slug(_ s: String) -> String {
        words(s).joined(separator: "-")
    }

    private static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func render(_ template: String, _ values: [String: String]) -> String {
        var out = template
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{\(key)}", with: value)
        }
        out = out.replacingOccurrences(of: #"[{}/:\\]"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([_\-.])[_\-.]+"#, with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "_-. "))
    }

    static func dateStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}
