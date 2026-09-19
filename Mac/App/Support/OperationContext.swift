//  OperationContext.swift
//
//  Frozen contract between the panel scope and every command scope (extract,
//  compress, tools). The panel registers a provider; commands read the context.
//  Do not change the shape of these types without the orchestrator's agreement:
//  four scopes compile against them in parallel.
//
//  Main thread only. `folder` is owned by the panel's serial queue, so a command
//  must not call folder methods on the main thread; hand it to an operation that
//  runs off-main (see Mac/docs/api/opsinfra.md).

import AppKit
import SevenZipKit

/// The items a command operates on, captured from the panel that invoked it.
struct OperationContext {
    /// The folder the active panel currently shows.
    let folder: SZFolder
    /// Path as shown in the address bar.
    let displayPath: String
    /// True when the folder is inside an archive.
    let isArchive: Bool
    /// True when the folder is a file-system folder.
    let isFileSystem: Bool
    /// Item indices in `folder` the command applies to: the selection, or the
    /// focused item when nothing is selected, matching 7zFM's "operated items"
    /// rule (01 §3).
    let indices: [Int]
    /// Names of `indices`, in the same order.
    let names: [String]
    /// Absolute file-system paths of `indices`. Empty when `isFileSystem` is false.
    let paths: [String]
    /// Absolute file-system path of the folder itself. Empty when the folder is
    /// not a file-system folder.
    let folderPath: String
    /// The other panel's file-system path when two panels are open, used as the
    /// default destination for copy and move. Nil with one panel.
    let otherPanelPath: String?
    /// The window the command should present sheets on.
    weak var window: NSWindow?
}

/// Implemented by the panel scope, consumed by the command scopes.
protocol OperationContextProviding: AnyObject {
    /// Context for the active panel, or nil when there is no active panel.
    func currentOperationContext() -> OperationContext?
    /// Re-read the active panel's folder and restore the selection, after an
    /// operation changed its contents.
    func refreshAfterOperation()
    /// Re-read both panels.
    func refreshAllPanels()
}

/// Registry the panel scope fills in and the command scopes read.
enum ActiveContext {
    private(set) static weak var provider: OperationContextProviding?

    /// Called by the panel scope when a window becomes active.
    static func register(_ provider: OperationContextProviding) {
        self.provider = provider
    }

    /// Context of the active panel, or nil when nothing is active.
    static func current() -> OperationContext? {
        provider?.currentOperationContext()
    }

    /// Refresh the active panel after an operation.
    static func refresh() {
        provider?.refreshAfterOperation()
    }

    /// Refresh both panels after an operation.
    static func refreshAll() {
        provider?.refreshAllPanels()
    }
}
