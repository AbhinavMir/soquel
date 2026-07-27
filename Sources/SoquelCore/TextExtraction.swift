import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Getting readable text out of a file, for the semantic index.
///
/// Only formats where the text is already there for the taking. Nothing is
/// converted, nothing is shelled out to, and a format that would need a parser
/// of its own is skipped rather than half-read.
enum TextExtraction {
    /// Files larger than this are skipped. A 40 MB log is not a document, and
    /// embedding it would cost more than the answer is worth.
    static let maximumBytes = 8 * 1024 * 1024

    /// Extensions read as plain text. Kept as a list rather than asking the
    /// system whether a type conforms to `public.text`, because that pulls in
    /// binary formats that merely declare a text type.
    static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "rst", "org", "tex",
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "env",
        "csv", "tsv", "log",
        "html", "htm", "xml", "svg", "css", "scss",
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "java", "kt",
        "py", "rb", "php", "pl", "lua", "sh", "bash", "zsh", "fish",
        "js", "jsx", "ts", "tsx", "vue", "sql", "r", "jl", "hs", "ex", "exs",
    ]

    static func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "pdf" || ext == "rtf" || plainTextExtensions.contains(ext)
    }

    /// The file's text, or nil when there is none worth having.
    static func text(of url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard (values?.fileSize ?? 0) <= maximumBytes else { return nil }

        switch url.pathExtension.lowercased() {
        case "pdf":
            return pdfText(url)
        case "rtf":
            guard let data = try? Data(contentsOf: url),
                  let attributed = try? NSAttributedString(
                      data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                      documentAttributes: nil)
            else { return nil }
            return clean(attributed.string)
        default:
            guard plainTextExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            // Files that are not valid UTF-8 are not text as far as this is
            // concerned; guessing an encoding produces mojibake, which then
            // embeds as nonsense.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return clean(text)
        }
    }

    private static func pdfText(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var pages: [String] = []
        // A book-length PDF is mostly noise for this purpose, and reading all of
        // it is the slowest thing the indexer would ever do.
        for index in 0..<min(document.pageCount, 80) {
            if let page = document.page(at: index), let text = page.string {
                pages.append(text)
            }
        }
        let joined = pages.joined(separator: "\n")
        return joined.isEmpty ? nil : clean(joined)
    }

    /// Collapses runs of whitespace. PDFs in particular arrive full of hard
    /// line breaks mid-sentence, which split sentences the embedding would
    /// otherwise read whole.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into passages of roughly `target` characters, breaking on
    /// paragraph and then sentence boundaries.
    ///
    /// Whole files are not embedded: a vector for a 40-page document means
    /// nothing in particular. A passage is the unit a person would point at
    /// and say "this is the bit I meant".
    static func passages(_ text: String, target: Int = 900, overlap: Int = 120) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 24 }

        var result: [String] = []
        var current = ""

        for paragraph in paragraphs {
            if paragraph.count >= target {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(contentsOf: split(paragraph, target: target, overlap: overlap))
                continue
            }
            if current.count + paragraph.count + 2 > target {
                result.append(current)
                current = String(current.suffix(overlap)) + "\n" + paragraph
            } else {
                current += current.isEmpty ? paragraph : "\n\n" + paragraph
            }
        }
        if current.count > 24 { result.append(current) }
        return result
    }

    /// Splits one long paragraph at sentence ends where it can.
    private static func split(_ text: String, target: Int, overlap: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for sentence in text.components(separatedBy: ". ") {
            let piece = sentence.hasSuffix(".") ? sentence : sentence + "."
            if current.count + piece.count > target, !current.isEmpty {
                pieces.append(current)
                current = String(current.suffix(overlap)) + " " + piece
            } else {
                current += current.isEmpty ? piece : " " + piece
            }
        }
        if current.count > 24 { pieces.append(current) }
        return pieces
    }
}
