import Foundation

/// The photo files Lumen opens: JPEG, PNG, HEIC and camera RAW. HEIC and RAW originals export as JPEG.
public enum PhotoFormats {
    /// Camera RAW extensions, decoded with Core Image's RAW engine (the formats macOS supports for the camera).
    public static let raw: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq", "kdc", "mef", "mos", "mrw", "nef", "nrw",
        "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    ]
    /// Every extension a library or `lumen edit` opens.
    public static let opened: Set<String> = Set(["jpg", "jpeg", "png", "heic"]).union(raw)

    public static func isRaw(_ url: URL) -> Bool { raw.contains(url.pathExtension.lowercased()) }

    public static func opens(_ url: URL) -> Bool { opened.contains(url.pathExtension.lowercased()) }

    /// The file name an edited copy gets: JPEG and PNG keep theirs; HEIC and RAW become `.jpg`.
    public static func exportName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        guard ext == "heic" || raw.contains(ext) else { return url.lastPathComponent }
        return url.deletingPathExtension().lastPathComponent + ".jpg"
    }
}
