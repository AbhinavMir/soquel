import AppKit
import UniformTypeIdentifiers

/// Choosing which application opens a file, and changing the system-wide
/// default for its type.
///
/// The default is a Launch Services setting, not a Soquel one: changing it
/// here changes it for Finder and every other app too, which is what people
/// mean when they ask for it, and why the menu says so.
enum OpenWith {
    /// Applications registered as able to open `url`, best match first, with
    /// duplicates by bundle identifier removed.
    static func candidates(for url: URL) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) {
            let key = Bundle(url: app)?.bundleIdentifier ?? app.path
            if seen.insert(key).inserted { result.append(app) }
        }
        return result
    }

    static func defaultApplication(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    static func displayName(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path)
    }

    /// Opens without asking. Callers that can put up a sheet should go through
    /// `AppLaunchGuard.confirm` first.
    static func open(_ urls: [URL], with app: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
    }

    /// Opens after the heavy-application prompt, if one is warranted.
    static func open(_ urls: [URL], with app: URL, confirmingIn window: NSWindow?) {
        AppLaunchGuard.confirm(opening: urls, with: app, in: window) {
            open(urls, with: app)
        }
    }

    /// The type whose default handler would change, which is the file's own
    /// type rather than anything inherited.
    static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    }

    /// Makes `app` the system default for the type of `url`. The completion
    /// carries Launch Services' error, which is usually a missing bundle.
    static func setDefault(_ app: URL, forTypeOf url: URL, completion: @escaping (Error?) -> Void) {
        guard let type = contentType(of: url) else {
            completion(CocoaError(.fileReadUnknown))
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    /// "PNG image", for the menu title, falling back to the extension.
    static func typeDescription(of url: URL) -> String {
        if let type = contentType(of: url), let description = type.localizedDescription {
            return description
        }
        let ext = url.pathExtension
        return ext.isEmpty ? "this kind of file" : ".\(ext) files"
    }
}
