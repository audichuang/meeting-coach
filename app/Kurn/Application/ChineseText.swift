//
//  ChineseText.swift
//  Kurn
//
//  System ICU transforms the meeting coach needs: Simplified -> Traditional
//  for display and storage (the cloud transcriber mostly answers in
//  Simplified even when asked for zh-TW), and toneless pinyin so a spoken
//  name still matches when the recognizer picks a homophone (志明 / 致明 / 智明).
//

import Foundation

enum ChineseText {
    /// Character-level Simplified -> Traditional. Phrase-level Taiwan vocabulary
    /// (數據庫 -> 資料庫) is out of scope for ICU and is not attempted.
    static func traditional(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hans-Hant"), reverse: false) ?? text
    }

    static func tonelessPinyin(_ text: String) -> String {
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false) ?? text
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.lowercased().filter { !$0.isWhitespace }
    }

    /// Matcher for "the user was named": exact text, or any run of Han characters
    /// whose toneless pinyin equals the name's.
    static func nameMatcher(for name: String) -> @Sendable (String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return { _ in false } }
        let target = tonelessPinyin(name)
        let length = name.count
        return { text in
            if text.localizedCaseInsensitiveContains(name) { return true }
            let chars = Array(text)
            guard chars.count >= length else { return false }
            for start in 0...(chars.count - length) {
                let window = String(chars[start..<(start + length)])
                guard window.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) else { continue }
                if tonelessPinyin(window) == target { return true }
            }
            return false
        }
    }
}
