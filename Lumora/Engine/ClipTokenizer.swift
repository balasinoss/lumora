import Foundation

/// Byte-pair-encoding tokenizer used by CLIP text encoders (77 tokens, start/end markers).
final class ClipTokenizer {
    static let shared = ClipTokenizer()

    private var encoder: [String: Int32] = [:]
    private var ranks: [String: Int] = [:]          // "a b" -> rank
    private var byteToChar: [UInt8: Character] = [:]
    private var cache: [String: [String]] = [:]
    private let regex: NSRegularExpression
    let sot: Int32 = 49406, eot: Int32 = 49407
    private(set) var ready = false

    init() {
        regex = try! NSRegularExpression(
            pattern: "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+",
            options: [.caseInsensitive])
        load()
    }

    private func load() {
        // byte -> unicode mapping (printable bytes map to themselves, others to 256+n)
        var bs: [Int] = Array(Int(UInt8(ascii: "!"))...Int(UInt8(ascii: "~"))) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        var units: [String] = []
        for (b, c) in zip(bs, cs) {
            let ch = Character(UnicodeScalar(UInt32(c))!)
            byteToChar[UInt8(b)] = ch
        }
        // vocab order: the 256 byte characters in bs order, then the same with </w>
        for b in bs { units.append(String(byteToChar[UInt8(b)]!)) }
        var vocab = units + units.map { $0 + "</w>" }

        guard let url = Bundle.main.url(forResource: "clip_vocab", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var merges: [(String, String)] = []
        for line in lines.dropFirst() {   // first line is a version header
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            merges.append((String(parts[0]), String(parts[1])))
            if merges.count >= 49152 - 256 - 2 { break }
        }
        for (i, m) in merges.enumerated() {
            ranks[m.0 + " " + m.1] = i
            vocab.append(m.0 + m.1)
        }
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")
        for (i, v) in vocab.enumerated() { encoder[v] = Int32(i) }
        ready = true
    }

    private func bpe(_ token: String) -> [String] {
        if let c = cache[token] { return c }
        var word: [String] = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (Int, Int)? = nil   // (rank, index)
            for i in 0..<(word.count - 1) {
                if let r = ranks[word[i] + " " + word[i + 1]], best == nil || r < best!.0 { best = (r, i) }
            }
            guard let (_, _) = best else { break }
            let pairA = word[best!.1], pairB = word[best!.1 + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == pairA && word[i + 1] == pairB {
                    merged.append(pairA + pairB); i += 2
                } else {
                    merged.append(word[i]); i += 1
                }
            }
            word = merged
        }
        cache[token] = word
        return word
    }

    /// Returns exactly 77 token ids (zero padded).
    func encode(_ text: String, length: Int = 77) -> [Int32] {
        let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).lowercased()
        var ids: [Int32] = [sot]
        let ns = cleaned as NSString
        for m in regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: m.range)
            let mapped = String(piece.utf8.map { byteToChar[$0]! })
            for t in bpe(mapped) { if let id = encoder[t] { ids.append(id) } }
        }
        if ids.count > length - 1 { ids = Array(ids.prefix(length - 1)) }
        ids.append(eot)
        while ids.count < length { ids.append(0) }
        return ids
    }
}
