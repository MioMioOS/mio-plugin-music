//
//  MioPlugin.swift
//  MioIsland Plugin SDK
//
//  Duplicate of the protocol from the host app. At runtime, @objc
//  protocol conformance is matched by selector signatures, not by
//  module identity, so this standalone copy works for .bundle plugins.
//

import AppKit

@objc protocol MioPlugin: AnyObject {
    var id: String { get }
    var name: String { get }
    var icon: String { get }
    var version: String { get }
    func activate()
    func deactivate()
    func makeView() -> NSView
    @objc optional func viewForSlot(_ slot: String, context: [String: Any]) -> NSView?
}
