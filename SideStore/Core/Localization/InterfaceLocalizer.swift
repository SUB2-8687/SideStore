//
//  InterfaceLocalizer.swift
//  SideStore
//
//  스토리보드/XIB 로 만든 UIKit 화면의 문자열은 화면을 로드할 때 "시스템 언어" 기준으로 읽히며,
//  LanguageManager 의 Bundle.localizedString 스위즐을 거치지 않는다.
//  (예: 시스템 한국어 + 앱 언어 영어 → 탭 이름/설정 행 라벨이 한국어로 남음)
//  이 클래스는 시스템 언어와 직전 앱 언어의 .strings를 새 앱 언어와 대조해 표시 중인 UIKit 문구를 갱신하고,
//  UIKit 뷰/뷰컨트롤러가 화면에 붙는 시점에 문자열을 앱 언어로 바꿔 준다.
//  화면에 이미 표시된 문자열도 선택 언어로 되돌려 적용한다. 메인 스레드에서만 사용한다.
//

import UIKit
import ObjectiveC

final class InterfaceLocalizer: @unchecked Sendable {
    static let shared = InterfaceLocalizer()

    private var map: [String: String] = [:]
    private var currentLanguageCode: String?
    private var targetValues: Set<String> = []
    private var isActive = false
    private var hooksInstalled = false

    /// 언어 선택 메뉴에 쓰이는 고정 표기. 번역 대응표에서 제외한다.
    private static let languageNameLabels: [String] = ["English", "영어", "Korean", "한국어"]

    private init() {}

    /// 앱 언어가 바뀔 때마다 대응표를 다시 만든다.
    func refresh(targetLanguageCode: String) {
        let systemLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let systemCode = systemLanguage.split(separator: "-").first.map(String.init) ?? systemLanguage
        let sourceCodes = Set([systemCode, currentLanguageCode].compactMap { $0 })
            .filter { $0 != targetLanguageCode }
        let targetTables = Self.tables(for: targetLanguageCode)

        map = [:]
        targetValues = []
        isActive = false
        currentLanguageCode = targetLanguageCode

        // The same translated label can appear in several string catalogs with
        // slightly different English wording. Vote across catalogs instead of
        // dropping every label that has more than one possible translation.
        var votes: [String: [String: Int]] = [:]
        if !targetTables.isEmpty {
            for sourceCode in sourceCodes {
                let sourceTables = Self.tables(for: sourceCode)
                for (table, sourceStrings) in sourceTables {
                    guard let localizedStrings = targetTables[table] else { continue }
                    for (key, sourceValue) in sourceStrings {
                        guard let targetValue = localizedStrings[key], !targetValue.isEmpty, targetValue != sourceValue else { continue }
                        var targetCounts = votes[sourceValue] ?? [:]
                        targetCounts[targetValue, default: 0] += 1
                        votes[sourceValue] = targetCounts
                    }
                }
            }
        }

        var built: [String: String] = [:]
        for (sourceValue, targetCounts) in votes {
            let preferredTarget = targetCounts.sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }.first?.key
            if let preferredTarget { built[sourceValue] = preferredTarget }
        }

        // Xcode string catalogs are compiled into localized resources, but UIKit
        // static storyboard cells can retain their original Korean labels after
        // a runtime language change. Keep catalog-derived pairs as a deterministic
        // fallback so those already-instantiated cells are translated as well.
        if targetLanguageCode == "en" {
            built.merge(CatalogLocalizationFallback.koreanToEnglish) { _, fallback in fallback }
            built.merge(CatalogLocalizationFallback.navigationKoreanToEnglish) { _, fallback in fallback }
        } else if targetLanguageCode == "ko" {
            // 카탈로그에서 얻은 번역이 이미 있으면 유지한다. (예: "User Customizations" → "사용자 지정 항목"을
            // 폴백의 "사용자 지정"으로 덮어쓰면 언어를 바꿀 때마다 제목이 달라진다.)
            for (korean, english) in CatalogLocalizationFallback.koreanToEnglish where built[english] == nil {
                built[english] = korean
            }
            for (korean, english) in CatalogLocalizationFallback.navigationKoreanToEnglish where built[english] == nil {
                built[english] = korean
            }
        }

        // 언어 선택 메뉴의 언어 이름은 앱 언어와 무관하게 고정 표기(English / 한국어)다.
        // 대응표에 남아 있으면 메뉴 라벨이 "영어" / "Korean" 으로 다시 바뀌므로 제외한다.
        for name in Self.languageNameLabels { built.removeValue(forKey: name) }

        // 한국어 "검색"에 대응하는 영어 키가 Search / Discovery 두 개라 투표가 갈린다.
        // 검색창·검색 버튼 등 일반 UI 문구는 Search 로 고정한다.
        if targetLanguageCode == "en" { built["검색"] = "Search" }

        map = built
        targetValues = Set(built.values)
        isActive = !built.isEmpty
        if isActive { installHooksIfNeeded() }
    }
    // MARK: - 적용

    /// 이미 만들어진 뷰컨트롤러 트리(로드된 뷰 포함)에 즉시 적용한다. 뷰를 새로 로드하지는 않는다.
    func localizeTree(_ viewController: UIViewController) {
        if let tabBarController = viewController as? UITabBarController {
            Self.applyTabBarTitles(to: tabBarController)
        }

        guard isActive else { return }
        localize(viewController: viewController)
        for child in viewController.children { localizeTree(child) }
        if viewController.isViewLoaded { localizeSubtree(viewController.view) }
    }

    /// Keep tab labels deterministic during rapid language changes. Some catalog
    /// entries compile to empty strings for a locale, which can otherwise erase a tab title.
    static func applyTabBarTitles(to tabBarController: UITabBarController) {
        let manager = LanguageManager.shared
        let isKorean = manager.effectiveLanguageCode == "ko"
        let titles = isKorean
            ? ["뉴스", "저장소", "탐색", "내 앱", "설정"]
            : ["News", "Sources", "Browse", "My Apps", "Settings"]
        for (index, child) in (tabBarController.viewControllers ?? []).enumerated() where index < titles.count {
            if child.tabBarItem.title != titles[index] {
                child.tabBarItem.title = titles[index]
            }
        }
    }

    func localizeSubtree(_ view: UIView) {
        guard isActive else { return }
        localize(view: view)
        for sub in view.subviews { localizeSubtree(sub) }
        // 문구 길이가 언어마다 달라 이전 언어 기준 크기로 "New & Upda..." 처럼 잘리는 것을 막기 위해 레이아웃을 갱신한다.
        if let collectionView = view as? UICollectionView {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        view.setNeedsLayout()
    }

    func localize(viewController vc: UIViewController) {
        guard isActive else { return }
        if let t = vc.title, let n = translated(t) { vc.title = n }
        let item = vc.navigationItem
        if let t = item.title, let n = translated(t) { item.title = n }
        if let t = item.prompt, let n = translated(t) { item.prompt = n }
        if let t = item.backButtonTitle, let n = translated(t) { item.backButtonTitle = n }
        if let t = vc.tabBarItem.title, let n = translated(t) { vc.tabBarItem.title = n }
        for barItem in (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? []) {
            if let t = barItem.title, let n = translated(t) { barItem.title = n }
        }
        LocalizedDoneBarButtonItem.localize(in: item)
        localizeBackButton(of: vc)
    }

    /// 이전 화면 제목이 없거나 길면 UIKit 이 기기 언어의 시스템 문구("뒤로")를 직접 표시한다.
    /// 이 경우 앱 언어에 맞는 "Back" / "뒤로" 를 이전 화면의 backButtonTitle 로 지정한다.
    private func localizeBackButton(of vc: UIViewController) {
        guard let nav = vc.navigationController,
              let index = nav.viewControllers.firstIndex(of: vc), index > 0 else { return }
        let previous = nav.viewControllers[index - 1]
        let previousTitle = previous.navigationItem.title ?? previous.title ?? ""
        guard previousTitle.isEmpty || previousTitle.count > 14 else { return }
        previous.navigationItem.backButtonTitle = LanguageManager.shared.effectiveLanguageCode == "ko" ? "뒤로" : "Back"
    }

    func localize(view: UIView) {
        guard isActive else { return }

        if let label = view as? UILabel {
            if let text = label.text, let n = translated(text) {
                if let attributed = label.attributedText, attributed.length > 0 {
                    let mutable = NSMutableAttributedString(attributedString: attributed)
                    mutable.replaceCharacters(in: NSRange(location: 0, length: mutable.length), with: n)
                    label.attributedText = mutable
                } else {
                    label.text = n
                }
                label.invalidateIntrinsicContentSize()
                label.superview?.setNeedsLayout()
            }
        } else if let button = view as? UIButton {
            for state: UIControl.State in [.normal, .highlighted, .selected, .disabled] {
                if let t = button.title(for: state), let n = translated(t) { button.setTitle(n, for: state) }
            }
            if var configuration = button.configuration, let t = configuration.title, let n = translated(t) {
                configuration.title = n
                button.configuration = configuration
            }
        } else if let field = view as? UITextField {
            if let t = field.placeholder, let n = translated(t) { field.placeholder = n }
        } else if let segmented = view as? UISegmentedControl {
            for index in 0..<segmented.numberOfSegments {
                if let t = segmented.titleForSegment(at: index), let n = translated(t) {
                    segmented.setTitle(n, forSegmentAt: index)
                }
            }
        }
    }

    private func translated(_ text: String) -> String? {
        // 이미 앱 언어로 바뀐 문자열을 다시 바꾸지 않는다.
        guard !targetValues.contains(text) else { return nil }
        return map[text]
    }

    // MARK: - 번들 테이블

    private static func tables(for language: String) -> [String: [String: String]] {
        guard let dir = Bundle.main.path(forResource: language, ofType: "lproj"),
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [:] }
        var result: [String: [String: String]] = [:]
        for file in files where file.hasSuffix(".strings") {
            let name = String(file.dropLast(".strings".count))
            // Localizable도 포함해 이미 화면에 만들어진 코드 기반 UIKit 라벨을 다시 현지화한다.
            if name == "InfoPlist" { continue }
            if let dict = NSDictionary(contentsOfFile: dir + "/" + file) as? [String: String] {
                result[name] = dict
            }
        }
        return result
    }

    // MARK: - 훅

    private func installHooksIfNeeded() {
        guard !hooksInstalled else { return }
        hooksInstalled = true
        Self.exchange(UIView.self, #selector(UIView.didMoveToWindow), #selector(UIView.il_didMoveToWindow))
        Self.exchange(UIViewController.self, #selector(UIViewController.viewWillAppear(_:)), #selector(UIViewController.il_viewWillAppear(_:)))
    }

    private static func exchange(_ cls: AnyClass, _ original: Selector, _ swizzled: Selector) {
        guard let a = class_getInstanceMethod(cls, original),
              let b = class_getInstanceMethod(cls, swizzled) else { return }
        method_exchangeImplementations(a, b)
    }
}

private extension UIView {
    @objc func il_didMoveToWindow() {
        il_didMoveToWindow()   // 교체 후이므로 원래 구현이 호출된다.
        if window != nil { InterfaceLocalizer.shared.localize(view: self) }
    }
}

private extension UIViewController {
    @objc func il_viewWillAppear(_ animated: Bool) {
        il_viewWillAppear(animated)
        InterfaceLocalizer.shared.localize(viewController: self)
    }
}

/// 스토리보드의 시스템 "완료"(systemItem="done") 버튼은 UIKit 이 기기 언어로 직접 번역해서
/// 앱 언어를 바꿔도 "완료"로 남는다. 앱 언어를 따르는 제목의 일반 버튼으로 교체한다.
final class LocalizedDoneBarButtonItem: UIBarButtonItem {
    static var currentTitle: String {
        LanguageManager.shared.effectiveLanguageCode == "ko" ? "완료" : "Done"
    }

    /// 기존 버튼의 target / action 을 그대로 이어받아 교체용 버튼을 만든다.
    static func replacing(_ item: UIBarButtonItem) -> LocalizedDoneBarButtonItem {
        let replacement = LocalizedDoneBarButtonItem(title: currentTitle, style: .done, target: item.target, action: item.action)
        replacement.tintColor = item.tintColor
        replacement.isEnabled = item.isEnabled
        replacement.accessibilityLabel = item.accessibilityLabel
        replacement.accessibilityIdentifier = item.accessibilityIdentifier
        return replacement
    }

    func refreshTitle() {
        let title = Self.currentTitle
        if self.title != title { self.title = title }
    }

    /// 시스템 "완료" 버튼(제목·이미지·커스텀뷰가 없는 done 스타일)을 찾아 교체하고, 이미 교체한 버튼은 제목만 갱신한다.
    static func localize(in navigationItem: UINavigationItem) {
        func fixed(_ items: [UIBarButtonItem]?) -> [UIBarButtonItem]? {
            guard let items else { return nil }
            var changed = false
            let result = items.map { item -> UIBarButtonItem in
                if let existing = item as? LocalizedDoneBarButtonItem {
                    existing.refreshTitle()
                    return item
                }
                let isSystemDone = item.style == .done && item.image == nil && item.customView == nil
                    && item.menu == nil && item.action != nil && [nil, "완료", "Done"].contains(item.title)
                guard isSystemDone else { return item }
                changed = true
                return replacing(item)
            }
            return changed ? result : nil
        }
        if let right = fixed(navigationItem.rightBarButtonItems) { navigationItem.rightBarButtonItems = right }
        if let left = fixed(navigationItem.leftBarButtonItems) { navigationItem.leftBarButtonItems = left }
    }
}
