import Foundation

public struct NameContext: Sendable {
    public var date: Date
    public var width: Int?
    public var height: Int?
    public var processName: String?
    public var increment: Int
    public var calendar: Calendar

    public init(date: Date, width: Int?, height: Int?, processName: String?,
                increment: Int, calendar: Calendar = .current) {
        self.date = date
        self.width = width
        self.height = height
        self.processName = processName
        self.increment = increment
        self.calendar = calendar
    }
}

public enum NameParser {
    // Longest tokens first so %mo/%mi/%ms win over shorter prefixes.
    private static let tokenOrder = ["%width", "%height", "%mo", "%mi", "%ms",
                                     "%pn", "%rn", "%ra", "%y", "%d", "%h", "%s", "%i"]

    public static func render(_ template: String, context: NameContext) -> String {
        var rng = SystemRandomNumberGenerator()
        return render(template, context: context, rng: &rng)
    }

    public static func render(_ template: String, context: NameContext,
                              rng: inout some RandomNumberGenerator) -> String {
        let c = context.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond], from: context.date)
        func pad(_ v: Int, _ w: Int) -> String {
            String(format: "%0\(w)d", v)
        }

        var out = ""
        var i = template.startIndex
        outer: while i < template.endIndex {
            if template[i] == "%" {
                for token in tokenOrder where template[i...].hasPrefix(token) {
                    out += value(for: token, comps: c, context: context, pad: pad, rng: &rng)
                    i = template.index(i, offsetBy: token.count)
                    continue outer
                }
            }
            out.append(template[i])
            i = template.index(after: i)
        }
        return out
    }

    private static func value(for token: String, comps c: DateComponents, context: NameContext,
                              pad: (Int, Int) -> String,
                              rng: inout some RandomNumberGenerator) -> String {
        switch token {
        case "%y": return pad(c.year ?? 0, 4)
        case "%mo": return pad(c.month ?? 0, 2)
        case "%d": return pad(c.day ?? 0, 2)
        case "%h": return pad(c.hour ?? 0, 2)
        case "%mi": return pad(c.minute ?? 0, 2)
        case "%s": return pad(c.second ?? 0, 2)
        case "%ms": return pad((c.nanosecond ?? 0) / 1_000_000, 3)
        case "%width": return context.width.map(String.init) ?? ""
        case "%height": return context.height.map(String.init) ?? ""
        case "%pn": return sanitize(context.processName ?? "")
        case "%i": return String(context.increment)
        case "%rn": return String("0123456789".randomElement(using: &rng)!)
        case "%ra":
            let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            return String(alphabet.randomElement(using: &rng)!)
        default: return token
        }
    }

    static func sanitize(_ name: String) -> String {
        name.map { $0 == "/" || $0 == ":" ? "-" : $0 }.reduce(into: "") { $0.append($1) }
    }
}
