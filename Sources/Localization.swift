import Foundation

enum AppLanguage: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var displayName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

enum AppLanguagePreferences {
    private static let languageOverrideKey = "application.languageOverride"

    static var languageOverride: AppLanguage? {
        guard let rawValue = UserDefaults.standard.string(forKey: languageOverrideKey) else { return nil }
        return AppLanguage(rawValue: rawValue)
    }

    static var systemLanguage: AppLanguage {
        if let preferred = Bundle.main.preferredLocalizations.first,
           preferred.hasPrefix("zh") {
            return .simplifiedChinese
        }
        return .english
    }

    static var currentLanguage: AppLanguage {
        languageOverride ?? systemLanguage
    }

    static func select(_ language: AppLanguage) {
        if language == systemLanguage {
            UserDefaults.standard.removeObject(forKey: languageOverrideKey)
        } else {
            UserDefaults.standard.set(language.rawValue, forKey: languageOverrideKey)
        }
    }
}

enum L10n {
    private static let simplifiedChineseBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: AppLanguage.simplifiedChinese.rawValue, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }()

    static func string(_ key: String) -> String {
        guard AppLanguagePreferences.currentLanguage == .simplifiedChinese,
              let bundle = simplifiedChineseBundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
