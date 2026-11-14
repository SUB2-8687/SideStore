//
//  AppFormatters.swift
//  SideStore
//
//  DateFormatter / DateComponentsFormatter / ByteCountFormatter 는 기본적으로 기기(시스템) 언어를 따른다.
//  앱 언어를 영어로 바꿔도 날짜("2026. 11. 13. 오후 12:23")나 용량("501바이트"), 남은 기간("7일")이
//  한국어로 남는 문제를 막기 위해, 앱 언어(LanguageManager)를 따르는 포맷터를 제공한다.
//

import Foundation

/// 앱 언어를 따르는 DateFormatter. 코드에서 `locale` 을 직접 지정하면 그 값을 우선한다.
final class AppDateFormatter: DateFormatter, @unchecked Sendable {
    private var followsAppLanguage = true

    override init() {
        super.init()
        super.locale = LanguageManager.shared.locale
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var locale: Locale! {
        get { super.locale }
        set {
            followsAppLanguage = false
            super.locale = newValue
        }
    }

    private func syncWithAppLanguage() {
        guard followsAppLanguage else { return }
        let appLocale = LanguageManager.shared.locale
        if super.locale?.identifier != appLocale.identifier {
            super.locale = appLocale
        }
    }

    override func string(from date: Date) -> String {
        syncWithAppLanguage()
        return super.string(from: date)
    }

    override func string(for obj: Any?) -> String? {
        syncWithAppLanguage()
        return super.string(for: obj)
    }
}

/// 앱 언어를 따르는 DateComponentsFormatter ("7 days" / "7일" 등).
final class AppDateComponentsFormatter: DateComponentsFormatter, @unchecked Sendable {
    private func syncWithAppLanguage() {
        var appCalendar = Calendar.current
        appCalendar.locale = LanguageManager.shared.locale
        self.calendar = appCalendar
    }

    override func string(from ti: TimeInterval) -> String? {
        syncWithAppLanguage()
        return super.string(from: ti)
    }

    override func string(from components: DateComponents) -> String? {
        syncWithAppLanguage()
        return super.string(from: components)
    }

    override func string(from startDate: Date, to endDate: Date) -> String? {
        syncWithAppLanguage()
        return super.string(from: startDate, to: endDate)
    }
}

enum AppFormat {
    /// ByteCountFormatter 는 locale 을 지정할 수 없어 기기 언어로 단위를 표기한다.
    /// 앱 언어(영어/한국어)에 맞게 단위 표기만 보정한다. (예: "501바이트" ↔ "501 bytes", "59.9MB" ↔ "59.9 MB")
    static func bytes(_ count: Int64) -> String {
        let raw = ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
        return normalizeByteString(raw, languageCode: LanguageManager.shared.effectiveLanguageCode)
    }

    static func normalizeByteString(_ raw: String, languageCode: String) -> String {
        var text = raw
        if languageCode == "en" {
            text = text.replacingOccurrences(of: "바이트", with: " bytes")
            text = text.replacingOccurrences(of: "(\\d)(KB|MB|GB|TB|PB)", with: "$1 $2", options: .regularExpression)
        } else if languageCode == "ko" {
            text = text.replacingOccurrences(of: "Zero KB", with: "0KB")
            text = text.replacingOccurrences(of: " bytes", with: "바이트")
            text = text.replacingOccurrences(of: " byte", with: "바이트")
            text = text.replacingOccurrences(of: "(\\d) (KB|MB|GB|TB|PB)", with: "$1$2", options: .regularExpression)
        }
        return text
    }
}
