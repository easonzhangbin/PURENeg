import Foundation

enum L10n {
    private static let englishLocale = Locale(identifier: "en")
    private static let chineseLocale = Locale(identifier: "zh-Hans")
    private static let englishBundle = Bundle.main.resourceURL.flatMap {
        Bundle(url: $0.appendingPathComponent("en.lproj", isDirectory: true))
    }

    static var isEnglish: Bool { AppPreferences.language == "en" }
    static var locale: Locale { isEnglish ? englishLocale : chineseLocale }

    static func text(_ value: String.LocalizationValue, table: String = "Localizable") -> String {
        let locale = self.locale
        if locale == englishLocale, let englishBundle {
            return String(localized: value, table: table, bundle: englishBundle, locale: locale)
        }
        // Chinese is the source text. An empty table keeps the system language from selecting an English translation.
        return String(localized: value, table: "Source", locale: locale)
    }

    static func surface(_ value: String.LocalizationValue) -> String {
        text(value, table: "Surfaces")
    }
}
