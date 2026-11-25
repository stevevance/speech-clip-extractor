import Foundation

// Reading, trimming and writing WebVTT subtitle files.
enum VTT {
    static func load(_ url: URL) throws -> [Cue] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text)
    }

    /*
     * Parses VTT (and SRT, which has the same block shape). Each block is
     * separated by a blank line; a block without a "-->" timing line (the
     * WEBVTT header, NOTE and STYLE blocks) is skipped. Inline tags such as
     * <c> or <00:00:01.000> from YouTube captions are stripped.
     */
    static func parse(_ text: String) -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []

        // Walk each blank-line separated block.
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }

            // "00:01.000 --> 00:04.000 align:start" -> start and end; settings after the end time are ignored.
            let halves = lines[timingIndex].components(separatedBy: "-->")
            guard halves.count == 2,
                  let start = Timecode.parse(halves[0]),
                  let endString = halves[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
                  let end = Timecode.parse(String(endString)) else { continue }

            // Everything after the timing line is caption text.
            var body = lines[(timingIndex + 1)...].joined(separator: " ")
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            body = decodeEntities(body).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            // Pull off a diarization label like "[SPEAKER_00]: ".
            var speaker: String?
            if let range = body.range(of: #"^\[([^\]]+)\]:\s*"#, options: .regularExpression) {
                speaker = String(body[range]).trimmingCharacters(in: CharacterSet(charactersIn: "[]: "))
                body.removeSubrange(range)
            }
            cues.append(Cue(start: start, end: end, text: body, speaker: speaker))
        }
        return cues
    }

    /*
     * Cues for one clip, re-zeroed so the clip starts at 00:00.
     * Unlike the skill's script (which kept only cues fully inside the clip),
     * a cue that overlaps either edge is kept and trimmed to the clip, so the
     * first and last words still get captions.
     */
    static func clipCues(_ cues: [Cue], start: Double, end: Double) -> [Cue] {
        cues.compactMap { cue in
            guard cue.end > start, cue.start < end else { return nil }
            var copy = cue
            copy.start = max(cue.start, start) - start
            copy.end = min(cue.end, end) - start
            return copy.end - copy.start > 0.05 ? copy : nil
        }
    }

    // Writes cues as a numbered VTT file. keepSpeakers puts the "[SPEAKER_00]: " prefixes back.
    static func write(_ cues: [Cue], to url: URL, keepSpeakers: Bool) throws {
        var out = ["WEBVTT", ""]
        for (index, cue) in cues.enumerated() {
            out.append(String(index + 1))
            out.append("\(Timecode.vtt(cue.start)) --> \(Timecode.vtt(cue.end))")
            if keepSpeakers, let speaker = cue.speaker {
                out.append("[\(speaker)]: \(cue.text)")
            } else {
                out.append(cue.text)
            }
            out.append("")
        }
        try out.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
