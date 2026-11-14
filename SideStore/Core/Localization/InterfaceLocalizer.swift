//
//  InterfaceLocalizer.swift
//  SideStore
//
//  스토리보드/XIB 로 만든 UIKit 화면의 문자열은 화면을 로드할 때 "시스템 언어" 기준으로 읽히며,
//  LanguageManager 의 Bundle.localizedString 스위즐을 거치지 않는다.
//  (예: 시스템 한국어 + 앱 언어 영어 → 탭 이름/설정 행 라벨이 한국어로 남음)
//  이 클래스는 "시스템 언어 문자열 → 앱 언어 문자열" 대응표를 번들의 .strings 테이블에서 만들어 두고,
//  UIKit 뷰/뷰컨트롤러가 화면에 붙는 시점에 문자열을 앱 언어로 바꿔 준다.
//  앱 언어 == 시스템 언어이면 아무 것도 하지 않는다. 메인 스레드에서만 사용한다.
//

import UIKit
import ObjectiveC

final class InterfaceLocalizer: @unchecked Sendable {
    static let shared = InterfaceLocalizer()

    private var map: [String: String] = [:]
    private var targetValues: Set<String> = []
    private var isActive = false
    private var hooksInstalled = false

    private init() {}

    /// 앱 언어가 바뀔 때마다 대응표를 다시 만든다.
    func refresh(targetLanguageCode: String) {
        let systemLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let systemCode = systemLanguage.split(separator: "-").first.map(String.init) ?? systemLanguage

        map = [:]
        targetValues = []
        isActive = false

        guard systemCode != targetLanguageCode else { return }

        let systemTables = Self.tables(for: systemLanguage)
        let targetTables = Self.tables(for: targetLanguageCode)
        guard !systemTables.isEmpty, !targetTables.isEmpty else { return }

        var built: [String: String] = [:]
        var ambiguous: Set<String> = []
        for (table, systemStrings) in systemTables {
            guard let targetStrings = targetTables[table] else { continue }
            for (key, systemValue) in systemStrings {
                guard let targetValue = targetStrings[key], targetValue != systemValue else { continue }
                if let existing = built[systemValue], existing != targetValue {
                    ambiguous.insert(systemValue)
                } else {
                    built[systemValue] = targetValue
                }
            }
        }
        for key in ambiguous { built[key] = nil }

        map = built
        targetValues = Set(built.values)
        isActive = !built.isEmpty
        if isActive { installHooksIfNeeded() }
    }

    // MARK: - 적용

    /// 이미 만들어진 뷰컨트롤러 트리(로드된 뷰 포함)에 즉시 적용한다. 뷰를 새로 로드하지는 않는다.
    func localizeTree(_ viewController: UIViewController) {
        guard isActive else { return }
        localize(viewController: viewController)
        for child in viewController.children { localizeTree(child) }
        if viewController.isViewLoaded { localizeSubtree(viewController.view) }
    }

    func localizeSubtree(_ view: UIView) {
        guard isActive else { return }
        localize(view: view)
        for sub in view.subviews { localizeSubtree(sub) }
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
            // 코드 문자열(Localizable)은 이미 LanguageManager 가 처리한다.
            if name == "Localizable" || name == "InfoPlist" { continue }
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
