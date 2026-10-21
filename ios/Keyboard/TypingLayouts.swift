import Foundation
import JapaneseInput
import KoreanInput
import PinyinInput
import SpanishInput
import TypingInput
import VoxtMobileKit
import ZhuyinInput

/// Every typing layout this keyboard offers through the TypingInput contract.
/// Adding a layout is one line here plus its package, which implements the TypingInput contract.
/// Latin layouts without an entry still come from VoxtMobileKit's catalog.
enum TypingLayouts {
    /// Letter keys of a `.keys` layout as the shared key grid draws them, with shift applied.
    static func keys(_ rows: [[KeySpec]], shifted: Bool) -> [[TextKeyboardKey]] {
        rows.map { row in
            row.map { spec in
                let text = spec.text(shifted: shifted)
                return TextKeyboardKey(id: spec.id, kind: kind(spec.role), label: spec.role == .character ? (text ?? spec.label) : spec.label,
                                       text: text, alternates: spec.alternates)
            }
        }
    }

    private static func kind(_ role: KeySpec.Role) -> TextKeyboardKey.Kind {
        switch role {
        case .character, .modifier: .character
        case .shift: .shift
        case .delete: .delete
        case .space: .space
        case .return: .return
        case .numbers: .numbers
        case .voice: .voice
        }
    }

    /// Picks are remembered in the App Group (Settings can clear them); fuzzy
    /// z/zh, c/ch, s/sh follows the Settings switch on every conversion.
    private static let pinyin = PinyinLayout.descriptor(
        learning: PinyinLearning(fileURL: PinyinSettings.learnedWordsURL),
        fuzzy: { PinyinSettings.fuzzy(in: UserDefaults(suiteName: DictationChannel.appGroup) ?? .standard) })

    static let registry: LayoutRegistry = {
        do {
            return try LayoutRegistry([SpanishLayout.descriptor, JapaneseLayout.descriptor, ZhuyinLayout.descriptor, KoreanLayout.descriptor, pinyin])
        } catch {
            preconditionFailure("Duplicate typing layout id: \(error)")
        }
    }()
}
