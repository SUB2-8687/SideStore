//
//  String+Localization.swift
//  AltStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import UIKit

public extension String {
    init(formatted: String, comment: String? = nil, _ args: String...) {
        self.init(format: NSLocalizedString(formatted, comment: comment ?? ""), args)
    }
}

public func systemLocalizedString(_ string: String) -> String {
    let bundle = Bundle(for: UIApplication.self)
    let localizedString = bundle.localizedString(forKey: string, value: "com.sidestore.SystemLocalizedStringNotFound", table: nil)
    if localizedString == "com.sidestore.SystemLocalizedStringNotFound" {
        return NSLocalizedString(string, comment: "")
    }
    return localizedString
}

/// minimuxer 등 외부 모듈에서 영어로 만들어 전달하는 오류 문구를 가능한 범위에서 현지화합니다.
/// "접두어: 본문 Cause: 원인" 형태를 나눠서 각각 번역하며, 번역이 없으면 원문을 그대로 반환합니다.
public func localizedMinimuxerMessage(_ raw: String) -> String {
    func tr(_ s: String) -> String { NSLocalizedString(s, comment: "") }
    let whole = tr(raw)
    if whole != raw { return whole }

    var text = raw
    var cause: String? = nil
    if let r = text.range(of: " Cause: ") {
        cause = String(text[r.upperBound...])
        text = String(text[..<r.lowerBound])
    }
    var prefix: String? = nil
    if let r = text.range(of: ": ") {
        let p = String(text[..<r.lowerBound])
        if !p.contains(" ") {
            prefix = p
            text = String(text[r.upperBound...])
        }
    }
    var out = ""
    if let prefix = prefix { out += tr(prefix) + ": " }
    out += tr(text)
    if let cause = cause { out += " " + tr("Cause:") + " " + tr(cause) }
    return out
}
