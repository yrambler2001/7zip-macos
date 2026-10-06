// QuickActionInput.swift -- resolves a Finder Quick Action's attachments to file URLs
// (03-shell-integration-inventory.md section 6.1). Shared by the two Quick Action appexes and the
// unit tests; AppKit/Foundation only.

import Foundation
import os
import UniformTypeIdentifiers

private let log = Logger(subsystem: ExtensionHandoff.subsystem, category: "QuickAction")

/// Turns the Quick Action's attachments into file URLs.
///
/// finderfix: Finder does **not** offer `public.file-url` for a Quick Action. Measured on macOS 26:
/// a `.zip` arrives as one attachment whose only registered type is `public.zip-archive`, so the
/// original code -- which asked for `public.file-url` and skipped everything else -- produced an
/// empty selection and the action silently did nothing. Each attachment is now resolved by:
///  1. `public.file-url` when it is offered (other hosts, older systems);
///  2. `loadInPlaceFileRepresentation` of its content type, which yields the original file (not a
///     copy, and without reading it into memory);
///  3. `loadItem` of its content type, which some hosts answer with the file's URL.
/// Order is preserved; an attachment that resolves to nothing is dropped.
enum QuickActionInput {

    static func fileURLs(from providers: [NSItemProvider],
                         completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else { return completion([]) }
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            fileURL(from: provider) { url in
                DispatchQueue.main.async {
                    urls[index] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let resolved = urls.compactMap { $0 }
            log.log("resolved \(resolved.count, privacy: .public) of \(providers.count, privacy: .public) attachments")
            completion(resolved)
        }
    }

    /// One attachment, through the three steps above.
    static func fileURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        let fileURLType = UTType.fileURL.identifier
        let contentTypes = provider.registeredTypeIdentifiers.filter { $0 != fileURLType }
        let viaItem = { loadItem(provider, types: contentTypes, completion: completion) }
        let viaInPlace = { inPlace(provider, types: contentTypes) { url in
            if let url { completion(url) } else { viaItem() }
        } }
        if provider.hasItemConformingToTypeIdentifier(fileURLType) {
            loadItem(provider, types: [fileURLType]) { url in
                if let url { completion(url) } else { viaInPlace() }
            }
        } else {
            viaInPlace()
        }
    }

    private static func loadItem(_ provider: NSItemProvider, types: [String],
                                 completion: @escaping (URL?) -> Void) {
        guard let type = types.first else { return completion(nil) }
        provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
            if let url = fileURL(fromItem: value) {
                completion(url)
            } else {
                if let error {
                    log.error("loadItem \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                loadItem(provider, types: Array(types.dropFirst()), completion: completion)
            }
        }
    }

    private static func inPlace(_ provider: NSItemProvider, types: [String],
                                completion: @escaping (URL?) -> Void) {
        guard let type = types.first else { return completion(nil) }
        _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, isInPlace, error in
            // Only the original file will do: a copy in a temporary directory would make "Extract
            // to <name>/" write next to the copy and "Add to archive" name the archive after it.
            if let url, url.isFileURL, isInPlace {
                completion(url)
            } else {
                if let error {
                    log.error("in-place \(type, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
                inPlace(provider, types: Array(types.dropFirst()), completion: completion)
            }
        }
    }

    /// What `loadItem` may hand back for a file: a URL, an `NSURL`, the URL's data
    /// representation, or its string form.
    static func fileURL(fromItem value: NSSecureCoding?) -> URL? {
        if let url = value as? URL, url.isFileURL { return url }
        if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
           url.isFileURL { return url }
        if let string = value as? String, let url = URL(string: string), url.isFileURL { return url }
        return nil
    }
}
