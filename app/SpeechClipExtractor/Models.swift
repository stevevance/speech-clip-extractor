import Foundation

// One subtitle cue from a VTT (or SRT) file.
struct Cue: Identifiable, Hashable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    // Diarization label such as "SPEAKER_00", parsed from a "[SPEAKER_00]: " prefix.
    var speaker: String?
}

// One clip the user wants to export.
struct Clip: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var start: Double
    var end: Double
    var quote: String = ""
    var why: String = ""
    var include: Bool = true

    var duration: Double { max(0, end - start) }
}

// Converting seconds to and from the time strings shown in the app and written to VTT files.
enum Timecode {
    // "m:ss.s", or "h:mm:ss.s" once the time passes an hour.
    static func format(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = s - Double(h * 3600 + m * 60)
        if h > 0 {
            return String(format: "%d:%02d:%04.1f", h, m, sec)
        }
        return String(format: "%d:%04.1f", m, sec)
    }

    // VTT timestamp, always "HH:MM:SS.mmm".
    static func vtt(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let h = Int(s) / 3600
        let m = (Int(s) % 3600) / 60
        let sec = s - Double(h * 3600 + m * 60)
        return String(format: "%02d:%02d:%06.3f", h, m, sec)
    }

    /*
     * Accepts "75", "75.5", "1:15", "1:15.5" or "0:01:15.500".
     * A comma decimal (SRT style, "00:01:15,500") works too.
     */
    static func parse(_ string: String) -> Double? {
        let parts = string.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
            .map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}

// Turns a clip title into a safe filename piece: lowercase letters, digits and hyphens.
func slugify(_ string: String, maxLength: Int = 50) -> String {
    // Apostrophes are dropped rather than hyphenated, so "Everything's" becomes "everythings".
    let lowered = string.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
    var slug = ""
    var lastWasHyphen = false
    for ch in lowered {
        if ch.isASCII && (ch.isLetter || ch.isNumber) {
            slug.append(ch)
            lastWasHyphen = false
        } else if !lastWasHyphen && !slug.isEmpty {
            slug.append("-")
            lastWasHyphen = true
        }
    }
    while slug.hasSuffix("-") { slug.removeLast() }
    if slug.count > maxLength {
        slug = String(slug.prefix(maxLength))
        while slug.hasSuffix("-") { slug.removeLast() }
    }
    return slug.isEmpty ? "clip" : slug
}
