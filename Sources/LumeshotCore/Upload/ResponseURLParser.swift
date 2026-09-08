import Foundation

public struct ResponseContext: Sendable {
    public var body: String
    public var headers: [String: String]
    public var regexList: [String]
    public init(body: String, headers: [String: String], regexList: [String]) {
        self.body = body
        self.headers = headers
        self.regexList = regexList
    }
}

public enum ResponseURLParser {
    /// Fills in every token, or returns nil if any of them cannot be extracted.
    ///
    /// Nil matters because a template usually contains literal text too. An
    /// unresolvable token used to become the empty string, so
    /// "https://example.com/i/{json:data.id}.png" against an error body that
    /// carried no id assembled into "https://example.com/i/.png" — a non-empty
    /// string, and therefore reported as a successful upload and copied to the
    /// clipboard. Only the caller knows whether a given template is required, so
    /// this reports the failure instead of papering over it.
    public static func resolve(_ template: String, context: ResponseContext) -> String? {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]          // unmatched '{' — emit literally
                return out
            }
            let token = String(rest[rest.index(after: open)..<close])
            guard let value = value(for: token, context: context) else { return nil }
            out += value
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    /// The token's value, or nil when it cannot be extracted from this response.
    /// `{response}` is the one token that always resolves — an empty body is a
    /// real answer, not a missing one.
    private static func value(for token: String, context: ResponseContext) -> String? {
        if token == "response" { return context.body }
        if let arg = suffix(token, after: "json:") { return jsonValue(path: arg, body: context.body) }
        if let arg = suffix(token, after: "regex:") { return regexValue(spec: arg, context: context) }
        if let arg = suffix(token, after: "header:") {
            let lower = arg.lowercased()
            return context.headers.first { $0.key.lowercased() == lower }?.value
        }
        return nil   // unknown token
    }

    private static func suffix(_ token: String, after prefix: String) -> String? {
        token.hasPrefix(prefix) ? String(token.dropFirst(prefix.count)) : nil
    }

    /// Dotted path with optional `[n]` array indices, e.g. `data.files[0].url`.
    private static func jsonValue(path: String, body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var current: Any? = root
        for component in path.split(separator: ".") {
            var key = Substring(component)
            var indices: [Int] = []
            while let open = key.lastIndex(of: "["), key.hasSuffix("]") {
                let idxStr = key[key.index(after: open)..<key.index(before: key.endIndex)]
                if let i = Int(idxStr) { indices.insert(i, at: 0) }
                key = key[key.startIndex..<open]
            }
            if !key.isEmpty {
                current = (current as? [String: Any])?[String(key)]
            }
            for i in indices {
                guard let array = current as? [Any], i >= 0, i < array.count else { return nil }
                current = array[i]
            }
        }
        switch current {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    /// `N` (whole match of regexList[N-1]) or `N|G` (capture group G).
    private static func regexValue(spec: String, context: ResponseContext) -> String? {
        let parts = spec.split(separator: "|")
        guard let index = Int(parts.first ?? ""), index >= 1,
              index <= context.regexList.count,
              let regex = try? NSRegularExpression(pattern: context.regexList[index - 1]) else {
            return nil
        }
        let group = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let range = NSRange(context.body.startIndex..., in: context.body)
        guard let match = regex.firstMatch(in: context.body, range: range),
              group >= 0, group < match.numberOfRanges,
              let r = Range(match.range(at: group), in: context.body) else { return nil }
        return String(context.body[r])
    }
}
