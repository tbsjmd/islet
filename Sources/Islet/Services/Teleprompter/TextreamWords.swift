// Ported from Textream (https://github.com/f/textream)
// Copyright (c) 2026 Fatih Kadir Akin — MIT License; see THIRD_PARTY_NOTICES.md.

import Foundation

// MARK: - CJK-aware word splitting

extension Unicode.Scalar {
    var isCJK: Bool {
        let v = value
        return (v >= 0x4E00 && v <= 0x9FFF)    // CJK Unified Ideographs
            || (v >= 0x3400 && v <= 0x4DBF)    // CJK Extension A
            || (v >= 0x20000 && v <= 0x2A6DF)  // CJK Extension B
            || (v >= 0xF900 && v <= 0xFAFF)    // CJK Compatibility Ideographs
            || (v >= 0x3040 && v <= 0x309F)    // Hiragana
            || (v >= 0x30A0 && v <= 0x30FF)    // Katakana
            || (v >= 0xAC00 && v <= 0xD7AF)    // Hangul Syllables
    }
}

/// Splits text into display-ready words. CJK characters (Chinese, Japanese, Korean)
/// are split into individual characters so the flow layout can wrap them properly.
func splitTextIntoWords(_ text: String) -> [String] {
    let tokens = text.replacingOccurrences(of: "\n", with: " ")
        .split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
        .map { String($0) }

    var result: [String] = []
    for token in tokens {
        guard token.unicodeScalars.contains(where: { $0.isCJK }) else {
            result.append(token)
            continue
        }
        // Token contains CJK characters — split each CJK char individually;
        // consecutive non-CJK chars (e.g. Latin letters, digits) stay grouped.
        var buffer = ""
        for char in token {
            if char.unicodeScalars.first.map({ $0.isCJK }) == true {
                if !buffer.isEmpty {
                    result.append(buffer)
                    buffer = ""
                }
                result.append(String(char))
            } else {
                buffer.append(char)
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
    }
    return result
}
