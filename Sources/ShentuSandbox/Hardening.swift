import Foundation

/// Built-in rules that protect credentials, other apps' data and persistence locations.
/// They are always compiled last, so they override the profile's broader allows.
public struct Hardening: Sendable {
    public enum Protection: Sendable {
        /// Deny reading and writing (credential stores, other apps' data).
        case readWrite
        /// Deny writing only (persistence locations; reading them is harmless).
        case write
    }

    public struct Entry: Sendable {
        public var id: String
        public var title: String
        public var path: String
        public var protection: Protection
        /// For secrets matched by name anywhere under the home folder: a regex on the full path
        /// (then `path` is just "~"). Compiled as `(require-all (subpath home) (regex …))`.
        public var pattern: String? = nil
    }

    public static let entries: [Entry] = [
        Entry(id: "H-ssh", title: "SSH keys and config", path: "~/.ssh", protection: .readWrite),
        Entry(id: "H-aws", title: "AWS credentials", path: "~/.aws", protection: .readWrite),
        Entry(id: "H-gnupg", title: "GnuPG keyrings", path: "~/.gnupg", protection: .readWrite),
        Entry(id: "H-kube", title: "Kubernetes credentials", path: "~/.kube", protection: .readWrite),
        Entry(id: "H-gh", title: "GitHub CLI token", path: "~/.config/gh", protection: .readWrite),
        Entry(id: "H-gcloud", title: "Google Cloud credentials", path: "~/.config/gcloud", protection: .readWrite),
        Entry(id: "H-netrc", title: ".netrc passwords", path: "~/.netrc", protection: .readWrite),
        Entry(id: "H-docker", title: "Docker registry auth", path: "~/.docker/config.json", protection: .readWrite),
        Entry(id: "H-keychains", title: "User keychains", path: "~/Library/Keychains", protection: .readWrite),
        Entry(id: "H-system-keychains", title: "System keychains", path: "/Library/Keychains", protection: .readWrite),
        Entry(id: "H-cookies", title: "Other apps' cookies", path: "~/Library/Cookies", protection: .readWrite),
        Entry(id: "H-safari", title: "Safari data", path: "~/Library/Safari", protection: .readWrite),
        Entry(id: "H-messages", title: "Messages history", path: "~/Library/Messages", protection: .readWrite),
        Entry(id: "H-mail", title: "Mail data", path: "~/Library/Mail", protection: .readWrite),
        Entry(id: "H-containers", title: "Other apps' sandbox containers", path: "~/Library/Containers", protection: .readWrite),
        Entry(id: "H-group-containers", title: "Other apps' group containers", path: "~/Library/Group Containers", protection: .readWrite),
        Entry(id: "H-chrome", title: "Chrome profile", path: "~/Library/Application Support/Google/Chrome", protection: .readWrite),
        Entry(id: "H-firefox", title: "Firefox profile", path: "~/Library/Application Support/Firefox", protection: .readWrite),
        Entry(id: "H-edge", title: "Edge profile", path: "~/Library/Application Support/Microsoft Edge", protection: .readWrite),
        Entry(id: "H-brave", title: "Brave profile", path: "~/Library/Application Support/BraveSoftware", protection: .readWrite),
        Entry(id: "H-arc", title: "Arc profile", path: "~/Library/Application Support/Arc", protection: .readWrite),
        Entry(id: "H-zsh-history", title: "zsh history", path: "~/.zsh_history", protection: .readWrite),
        Entry(id: "H-zsh-sessions", title: "zsh session history", path: "~/.zsh_sessions", protection: .readWrite),
        Entry(id: "H-bash-history", title: "bash history", path: "~/.bash_history", protection: .readWrite),
        Entry(id: "H-user-launchagents", title: "User launch agents (persistence)", path: "~/Library/LaunchAgents", protection: .write),
        Entry(id: "H-launchagents", title: "System launch agents (persistence)", path: "/Library/LaunchAgents", protection: .write),
        Entry(id: "H-launchdaemons", title: "Launch daemons (persistence)", path: "/Library/LaunchDaemons", protection: .write),
        Entry(id: "H-zshrc", title: "~/.zshrc (persistence)", path: "~/.zshrc", protection: .write),
        Entry(id: "H-zprofile", title: "~/.zprofile (persistence)", path: "~/.zprofile", protection: .write),
        Entry(id: "H-zshenv", title: "~/.zshenv (persistence)", path: "~/.zshenv", protection: .write),
        Entry(id: "H-zlogin", title: "~/.zlogin (persistence)", path: "~/.zlogin", protection: .write),
        Entry(id: "H-bashrc", title: "~/.bashrc (persistence)", path: "~/.bashrc", protection: .write),
        Entry(id: "H-bash-profile", title: "~/.bash_profile (persistence)", path: "~/.bash_profile", protection: .write),
        Entry(id: "H-profile", title: "~/.profile (persistence)", path: "~/.profile", protection: .write),
        // Sanity set: secrets by name, anywhere in the home folder.
        Entry(id: "H-env-files", title: ".env files", path: "~", protection: .readWrite,
              pattern: #"/\.env(\.[^/]*)?$"#),
        Entry(id: "H-key-files", title: "Key and certificate files (.pem .key .p12 .pfx) and KeePass vaults (.kdbx)",
              path: "~", protection: .readWrite, pattern: #"\.(pem|key|p12|pfx|kdbx)$"#),
        Entry(id: "H-ssh-keys-anywhere", title: "SSH private keys outside ~/.ssh", path: "~", protection: .readWrite,
              pattern: #"/id_(rsa|dsa|ecdsa|ed25519)[^/]*$"#),
        Entry(id: "H-git-credentials", title: "Git stored credentials", path: "~", protection: .readWrite,
              pattern: #"/\.git-credentials$"#),
        // More credential stores.
        Entry(id: "H-azure", title: "Azure credentials", path: "~/.azure", protection: .readWrite),
        Entry(id: "H-npmrc", title: "npm tokens", path: "~/.npmrc", protection: .readWrite),
        Entry(id: "H-pypirc", title: "PyPI tokens", path: "~/.pypirc", protection: .readWrite),
        Entry(id: "H-gem", title: "RubyGems credentials", path: "~/.gem/credentials", protection: .readWrite),
        Entry(id: "H-cargo", title: "Cargo registry tokens", path: "~/.cargo/credentials", protection: .readWrite),
        Entry(id: "H-cargo-toml", title: "Cargo registry tokens", path: "~/.cargo/credentials.toml", protection: .readWrite),
        Entry(id: "H-op", title: "1Password CLI", path: "~/.config/op", protection: .readWrite),
        Entry(id: "H-pass", title: "pass password store", path: "~/.password-store", protection: .readWrite),
        Entry(id: "H-terraform", title: "Terraform credentials", path: "~/.terraform.d", protection: .readWrite),
        Entry(id: "H-vault", title: "Vault token", path: "~/.vault-token", protection: .readWrite),
        Entry(id: "H-pgpass", title: "PostgreSQL passwords", path: "~/.pgpass", protection: .readWrite),
        Entry(id: "H-mycnf", title: "MySQL passwords", path: "~/.my.cnf", protection: .readWrite),
        Entry(id: "H-doctl", title: "DigitalOcean credentials", path: "~/.config/doctl", protection: .readWrite),
        // Chat apps: their data folders hold session tokens.
        Entry(id: "H-slack", title: "Slack sessions", path: "~/Library/Application Support/Slack", protection: .readWrite),
        Entry(id: "H-discord", title: "Discord sessions", path: "~/Library/Application Support/discord", protection: .readWrite),
        Entry(id: "H-signal", title: "Signal data", path: "~/Library/Application Support/Signal", protection: .readWrite),
        Entry(id: "H-telegram", title: "Telegram sessions", path: "~/Library/Application Support/Telegram Desktop", protection: .readWrite),
        Entry(id: "H-whatsapp", title: "WhatsApp data", path: "~/Library/Application Support/WhatsApp", protection: .readWrite),
        // Personal data (Notes and Voice Memos live in Group Containers, already protected).
        Entry(id: "H-contacts", title: "Contacts", path: "~/Library/Application Support/AddressBook", protection: .readWrite),
        Entry(id: "H-calendars", title: "Calendars", path: "~/Library/Calendars", protection: .readWrite),
        Entry(id: "H-photos", title: "Photos library", path: "~/Pictures/Photos Library.photoslibrary", protection: .readWrite),
    ]

    let environment: ShentuEnvironment
    /// Absolute paths of folders the app owns. Sensitive entries never block the app's own data.
    let ownAnchors: [String]

    public init(environment: ShentuEnvironment, ownAnchors: [String]) {
        self.environment = environment
        self.ownAnchors = ownAnchors
    }

    /// The sanity set as rules. An entry inside one of the app's own folders is allowed; an own
    /// folder inside a protected entry is re-allowed right after the entry's deny.
    func rules() -> [SBPLRule] {
        var rules: [SBPLRule] = []
        for entry in Self.entries {
            let full = environment.expand(entry.path)
            let operations = entry.protection == .readWrite ? ["file-read*", "file-write*"] : ["file-write*"]
            let filter: SBPLFilter = entry.pattern.map { .homePattern($0) } ?? .subpath(entry.path)
            if entry.pattern == nil, ownAnchors.contains(where: { full.isWithin($0) }) {
                rules.append(SBPLRule(.allow, operations, filter))
                continue
            }
            rules.append(SBPLRule(.deny, operations, filter))
            // The deny above would also block the app's own folder inside it (e.g. its own
            // group container), so re-allow exactly that folder right after.
            for own in ownAnchors where entry.pattern == nil && own.isWithin(full) && own != full {
                rules.append(SBPLRule(.allow, operations, .subpath(environment.abbreviate(own))))
            }
        }
        rules.append(SBPLRule(.deny, ["appleevent-send"]))
        rules.append(SBPLRule(.deny, ["process-exec*"], .literal("/usr/bin/osascript")))
        return rules
    }
}

extension String {
    /// True if self equals `root` or lies underneath it.
    func isWithin(_ root: String) -> Bool {
        self == root || hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
