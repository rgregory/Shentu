import UniformTypeIdentifiers

/// File kinds as Finder's Kind menu names them, minus the ones that aren't files you open:
/// Application and Executable (programs), Folder (folders are always listable) and Other
/// (everything). Membership is decided by macOS's own type system (UTType conformance); the
/// resulting extensions go into the profile, where they can be read in an audit.
public enum FileKind: String, CaseIterable, Codable, Sendable {
    case archive, document, image, movie, music, pdf, presentation, text

    /// Finder's word for the kind.
    public var title: String {
        switch self {
        case .pdf: return "PDF"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }

    /// Candidate extensions; each is kept only if macOS puts it in this kind. Left out on purpose
    /// although macOS files them here: `.ts` (also TypeScript source), `.key` (also private keys).
    static let candidates: [FileKind: String] = [
        .archive: "zip rar 7z tar gz tgz bz2 xz cpio",
        .document: "doc docx odt pages rtf xls xlsx ods numbers csv epub",
        .image: "jpg jpeg png gif heic heif tif tiff bmp webp raw cr2 nef arw dng ico psd svg",
        .movie: "mp4 m4v mov avi mkv wmv flv webm mpg mpeg m2ts mts 3gp ogv vob divx",
        .music: "mp3 m4a m4b aac wav aiff aif flac ogg oga opus wma mid midi caf amr ac3",
        .pdf: "pdf",
        .presentation: "ppt pptx odp",
        .text: "txt text md markdown",
    ]

    /// The extensions macOS puts in this kind on this Mac.
    public var extensions: [String] {
        (Self.candidates[self] ?? "").split(separator: " ").map(String.init).filter { ext in
            guard let type = UTType(filenameExtension: ext), !type.isDynamic else { return false }
            // Never code or scripts, which is where secrets tend to live.
            if type.conforms(to: .sourceCode) || type.conforms(to: .script) { return false }
            switch self {
            case .archive: return type.conforms(to: .archive)
            case .document:
                return !type.conforms(to: .presentation) && !type.conforms(to: .pdf)
                    && (type.conforms(to: .compositeContent) || type.conforms(to: .spreadsheet)
                        || type.conforms(to: .rtf) || type.conforms(to: .commaSeparatedText))
            case .image: return type.conforms(to: .image)
            case .movie: return type.conforms(to: .movie)
            case .music: return type.conforms(to: .audio)
            case .pdf: return type.conforms(to: .pdf)
            case .presentation: return type.conforms(to: .presentation)
            case .text: return type.conforms(to: .plainText)
            }
        }
    }
}
