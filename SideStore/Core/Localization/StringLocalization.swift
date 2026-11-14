//
//  String+Localization.swift
//  SideStore
//
//  Created by Magesh K on 12/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

@inline(__always)
public func localizedString(_ key: String, tableName: String? = nil) -> String {
    let bundle = LanguageManager.shared.bundle
    return bundle.localizedString(forKey: key, value: key, table: tableName)
}

@inline(__always)
public func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: LanguageManager.shared.bundle, locale: LanguageManager.shared.locale)
}

@inline(__always)
public func localized(_ value: String.LocalizationValue, comment: StaticString) -> String {
    String(localized: value, bundle: LanguageManager.shared.bundle, locale: LanguageManager.shared.locale, comment: comment)
}

/// Foundation 의 NSLocalizedString 을 앱 모듈 안에서 대체(shadow)한다.
///
/// 기존 코드 1,000여 곳의 NSLocalizedString("...", comment: "") 호출은 Bundle.main 을 시스템 언어로 조회하며,
/// 앱 내 언어 선택(LanguageManager)을 반영하려면 Bundle.localizedString 스위즐에 의존해야 했다.
/// 스위즐 경로는 화면/상태에 따라 반영되지 않는 경우가 있어(예: "Ready to pair", "No ... found on Developer Portal.",
/// "PRIMARY CLIENT HEADERS", "%d registered" 등이 영어로 남음), 호출 시점마다 현재 앱 언어 번들에서
/// 직접 조회하도록 한다. Swift 는 현재 모듈의 선언을 import 된 선언보다 우선하므로 호출부 수정 없이 적용된다.
public func NSLocalizedString(
    _ key: String,
    tableName: String? = nil,
    bundle: Bundle = Bundle.main,
    value: String = "",
    comment: String
) -> String {
    // 호출부가 Bundle.main 이 아닌 번들을 명시했다면 그대로 존중한다.
    let target: Bundle = (bundle === Bundle.main) ? LanguageManager.shared.bundle : bundle
    return target.localizedString(forKey: key, value: value, table: tableName)
}
