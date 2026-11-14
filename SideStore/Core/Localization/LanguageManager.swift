//
//  LanguageManager.swift
//  SideStore
//
//  Created by Magesh K on 12/09/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import ObjectiveC
import SwiftUI
import Combine

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case english = "en"
    case korean = "ko"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        // 선택한 앱 언어 번들을 명시적으로 사용해야 Picker 항목도 앱 언어로 표시된다.
        case .system:
            return localized("System")
        case .english:
            return "English"
        case .korean:
            return localized("Korean")
        }
    }
}

public final class LanguageManager: ObservableObject {
    public static let shared = LanguageManager()
    
    /// 앱 언어가 바뀐 직후(번들 교체 완료 후) 메인 큐에서 게시되는 알림.
    /// UIKit(스토리보드) 화면은 이 알림을 받아 UI 를 다시 구성합니다.
    public static let languageDidChangeNotification = Notification.Name("LanguageManager.languageDidChange")
    
    @Published public var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.selectedAppLanguage = selectedLanguage.rawValue
            updateBundleOverride()
            // Picker 선택 처리 도중에 화면을 갈아끼우지 않도록 다음 런루프에서 알린다.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: LanguageManager.languageDidChangeNotification, object: nil)
            }
        }
    }
    
    @Published public private(set) var effectiveLanguageCode: String = "en"
    
    public var locale: Locale {
        Locale(identifier: effectiveLanguageCode)
    }

    /// 선택한 언어의 .lproj 번들 (없으면 Bundle.main).
    /// SwiftUI 의 Text("...") / String(localized:) 는 Bundle.localizedString 스위즐을 거치지 않고
    /// 시스템 언어로 직접 조회하므로, 이 번들과 locale 을 명시적으로 넘겨야 앱 내 언어 선택이 반영됩니다.
    public var bundle: Bundle {
        (objc_getAssociatedObject(Bundle.main, &bundleAssociationKey) as? Bundle) ?? Bundle.main
    }
    
    private init() {
        let saved = UserDefaults.standard.selectedAppLanguage ?? AppLanguage.system.rawValue
        let initial = AppLanguage(rawValue: saved) ?? .system
        self.selectedLanguage = initial
        self.effectiveLanguageCode = LanguageManager.resolveEffectiveLanguageCode(for: initial)
        self.updateBundleOverride()
    }
    
    private static func resolveEffectiveLanguageCode(for language: AppLanguage) -> String {
        switch language {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if preferred.hasPrefix("ko") {
                return "ko"
            }
            return "en"
        case .english:
            return "en"
        case .korean:
            return "ko"
        }
    }
    
    private func updateBundleOverride() {
        let code = LanguageManager.resolveEffectiveLanguageCode(for: selectedLanguage)
        // 순서 중요: 번들/대응표를 먼저 교체한 뒤 effectiveLanguageCode 를 게시해야,
        // 이를 관찰하는 SwiftUI 화면이 다시 그려질 때 이미 새 언어 번들로 문자열을 조회한다.
        LocalizedBundleHelper.setCurrentLanguage(code)
        // 스토리보드/XIB 문자열은 시스템 언어로 로드되므로, 화면에 붙을 때 앱 언어로 바꿔 주는 대응표를 갱신한다.
        InterfaceLocalizer.shared.refresh(targetLanguageCode: code)
        effectiveLanguageCode = code
    }
}

private var bundleAssociationKey: UInt8 = 0

private final class LocalizedBundleHelper {
    static func setCurrentLanguage(_ languageCode: String) {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            objc_setAssociatedObject(Bundle.main, &bundleAssociationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        objc_setAssociatedObject(Bundle.main, &bundleAssociationKey, localizedBundle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        staticSwizzleOnce
    }
    
    private static let staticSwizzleOnce: Void = {
        let originalSelector = #selector(Bundle.localizedString(forKey:value:table:))
        let swizzledSelector = #selector(Bundle.customLocalizedString(forKey:value:table:))
        
        guard let originalMethod = class_getInstanceMethod(Bundle.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(Bundle.self, swizzledSelector) else {
            return
        }
        
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }()
}

private extension Bundle {
    @objc func customLocalizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let customBundle = objc_getAssociatedObject(self, &bundleAssociationKey) as? Bundle {
            return customBundle.customLocalizedString(forKey: key, value: value, table: tableName)
        }
        return self.customLocalizedString(forKey: key, value: value, table: tableName)
    }
}

/// 앱 언어(locale)를 SwiftUI 환경에 주입하고, 언어가 바뀌면 이미 열려 있는 화면도 즉시 다시 그린다.
///
/// 기존 구현은 화면을 만드는 시점의 locale 값을 한 번만 environment 에 넣었기 때문에,
/// 호스팅 컨트롤러가 이미 떠 있는 상태에서 언어가 바뀌면 Text("...") 는 물론
/// NSLocalizedString 으로 만든 문자열(헤더/푸터/빈 목록 문구/상태 문구 등)이 이전 언어로 남았다.
public struct AppLanguageEnvironmentModifier: ViewModifier {
    @ObservedObject private var manager: LanguageManager
    private let rebuildsOnChange: Bool

    public init(manager: LanguageManager, rebuildsOnChange: Bool) {
        self.manager = manager
        self.rebuildsOnChange = rebuildsOnChange
    }

    public func body(content: Content) -> some View {
        content
            .environment(\.locale, manager.locale)
            // 코드에서 NSLocalizedString/localized() 로 미리 계산한 문자열은 body 가 다시 평가되어야 바뀐다.
            // 언어가 바뀌면 화면 트리를 새로 만들어 모든 문자열을 새 언어로 다시 계산한다.
            // (언어 선택 화면처럼 스스로 상태를 유지해야 하는 화면은 rebuildsOnChange: false 로 호출)
            .id(rebuildsOnChange ? manager.effectiveLanguageCode : "app-language-static")
    }
}

public extension View {
    /// 앱 내에서 선택한 언어를 SwiftUI 환경(locale)에 적용합니다.
    /// 가장 바깥쪽(마지막) modifier 로 붙여야 navigationTitle / alert 까지 모두 반영됩니다.
    /// 언어가 바뀌면 이미 표시 중인 화면도 즉시 새 언어로 갱신됩니다.
    func appLanguageEnvironment(_ manager: LanguageManager = .shared, rebuildsOnChange: Bool = true) -> some View {
        modifier(AppLanguageEnvironmentModifier(manager: manager, rebuildsOnChange: rebuildsOnChange))
    }
}
