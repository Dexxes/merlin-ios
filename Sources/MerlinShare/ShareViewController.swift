import UIKit
import UniformTypeIdentifiers
import Security

class ShareViewController: UIViewController {

    // MARK: – Keychain credential store
    // Reads from the same Keychain access group as the main Merlin app.
    // No App Groups required — Keychain sharing is provisioned via xtool.

    // Identisch mit dem accessGroup-Wert in CredentialsStore der Hauptapp.
    private let keychainAccessGroup = "2R735BXV66.XTL-2R735BXV66.dev.merlin.app"
    private let keychainService     = "dev.merlin.app"

    private enum Account: String {
        case nextcloudUrl = "nextcloudUrl"
        case username     = "username"
        case appPassword  = "appPassword"
        case backendKind  = "backendKind"
    }

    private func keychainRead(_ account: Account) -> String? {
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     keychainService,
            kSecAttrAccount:     account.rawValue,
            kSecAttrAccessGroup: keychainAccessGroup,
            kSecReturnData:      true,
            kSecMatchLimit:      kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data   = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private func keychainWrite(_ value: String, for account: Account) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrService:     keychainService,
            kSecAttrAccount:     account.rawValue,
            kSecAttrAccessGroup: keychainAccessGroup,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    private var storedURL: String {
        get { keychainRead(.nextcloudUrl) ?? "" }
        set {
            keychainWrite(
                newValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/$", with: "", options: .regularExpression),
                for: .nextcloudUrl
            )
        }
    }
    private var storedUsername: String {
        get { keychainRead(.username) ?? "" }
        set { keychainWrite(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .username) }
    }
    private var storedPassword: String {
        get { keychainRead(.appPassword) ?? "" }
        set { keychainWrite(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: .appPassword) }
    }

    private var isConfigured: Bool {
        !storedURL.isEmpty && !storedUsername.isEmpty && !storedPassword.isEmpty
    }

    /// Muss dieselbe Logik wie CredentialsStore.BackendKind der Hauptapp
    /// spiegeln (gleicher Keychain-Wert, gleicher Default) - siehe dortigen
    /// Kommentar zur Nextcloud-vs-merlin-server-Unterscheidung.
    private var apiPrefix: String {
        keychainRead(.backendKind) == "standalone" ? "/api" : "/index.php/apps/merlin/api"
    }

    // MARK: – Shared UI

    private let containerView: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        v.layer.cornerRadius = 16
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let iconView: UIImageView = {
        let bundle = Bundle(for: ShareViewController.self)
        let logo = UIImage(named: "MerlinLogo", in: bundle, compatibleWith: nil)
        let iv = UIImageView(image: logo)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "Merlin"
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let subtitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // MARK: – Saving UI

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    /// Upload progress of shared files (hidden while saving a link).
    private let progressView: UIProgressView = {
        let p = UIProgressView(progressViewStyle: .default)
        p.translatesAutoresizingMaskIntoConstraints = false
        p.isHidden = true
        return p
    }()

    // MARK: – Staging UI (confirm URL + optional tags before saving)

    private let urlPreviewLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingMiddle
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Vertical scroll view that holds the existing tags as an indented tree
    // (sub-tags below their parent tag)
    private let tagChipsScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.alwaysBounceVertical = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()
    private let tagChipsStack: UIStackView = {
        let s = UIStackView()
        s.axis = .vertical
        s.spacing = 2
        s.alignment = .fill
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    private static let tagRowHeight: CGFloat = 36
    /// Visible rows before the tag list scrolls.
    private static let maxVisibleTagRows = 5
    private lazy var tagListHeightConstraint =
        tagChipsScrollView.heightAnchor.constraint(equalToConstant: Self.tagRowHeight)
    private let tagsLoadingLabel: UILabel = {
        let l = UILabel()
        l.text = L("share.staging.loadingTags")
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let tagsField: UITextField = {
        let f = UITextField()
        f.placeholder = L("share.staging.newTagPlaceholder")
        f.borderStyle = .roundedRect
        f.font = .systemFont(ofSize: 15)
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.returnKeyType = .done
        f.heightAnchor.constraint(equalToConstant: 44).isActive = true
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }()

    private let confirmSaveButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L("share.staging.saveButton")
        config.cornerStyle = .medium
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs; a.font = UIFont.systemFont(ofSize: 18, weight: .semibold); return a
        }
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 56).isActive = true
        return btn
    }()

    private lazy var stagingStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            urlPreviewLabel,
            tagChipsScrollView,
            tagsField,
            confirmSaveButton
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // Available tags fetched from server; selected ones tracked separately
    private struct ShareTag { let id: Int; let name: String; let parentId: Int? }
    private var availableTags: [ShareTag] = []
    private var selectedTagIds: Set<Int> = []
    private var tagButtons: [Int: UIButton] = [:]

    private var pendingURL: String = ""
    /// Files from the share payload (photos, videos, PDFs …) when it carries no web link.
    /// They go into the Nextcloud folder "Merlin Dateien" (see FileUploader).
    private var pendingFiles: [SharedFile] = []
    private var isDone = false

    // MARK: – Settings UI

    private lazy var settingsStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [
            makeField(urlField,      placeholder: L("share.settings.urlPlaceholder"), keyboard: .URL),
            makeField(usernameField, placeholder: L("share.settings.usernamePlaceholder")),
            makeField(passwordField, placeholder: L("share.settings.passwordPlaceholder"), secure: true),
            saveButton
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let urlField      = UITextField()
    private let usernameField = UITextField()
    private let passwordField = UITextField()

    private let saveButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = L("share.settings.saveButton")
        config.cornerStyle = .medium
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }()

    private var containerHeightConstraint: NSLayoutConstraint?
    private var containerBottomConstraint: NSLayoutConstraint?

    // MARK: – Lifecycle

    private var didForceFullScreen = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        if isConfigured {
            showExtractingMode()
            extractContent()
        } else {
            showSettingsMode()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Force full-screen here — view is already in the window so superviews are
        // reachable, but the presentation animation hasn't started yet so there's
        // no visible frame jump. Guard ensures we only do this once.
        if !didForceFullScreen {
            didForceFullScreen = true
            view.frame = UIScreen.main.bounds
            var sv = view.superview
            while let s = sv { s.clipsToBounds = false; sv = s.superview }
        }
        NotificationCenter.default.addObserver(self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let info = notification.userInfo,
              let keyboardFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }

        let keyboardHeight = keyboardFrame.height
        containerBottomConstraint?.constant = -keyboardHeight
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }

        containerBottomConstraint?.constant = 0
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    // MARK: – Layout

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)

        view.addSubview(containerView)
        containerView.addSubview(iconView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(subtitleLabel)

        // Saving-mode views
        containerView.addSubview(activityIndicator)
        containerView.addSubview(statusLabel)
        containerView.addSubview(progressView)

        // Staging-mode views
        containerView.addSubview(stagingStack)

        // Settings-mode views
        containerView.addSubview(settingsStack)

        let heightC = containerView.heightAnchor.constraint(equalToConstant: 220)
        let bottomC = containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        containerHeightConstraint = heightC
        containerBottomConstraint = bottomC

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomC,
            heightC,

            iconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            iconView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 40),
            iconView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: iconView.topAnchor),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            // Saving mode
            activityIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            activityIndicator.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 28),

            statusLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            progressView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            progressView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            progressView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Settings mode
            settingsStack.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 20),
            settingsStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            settingsStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            // Staging mode
            stagingStack.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 20),
            stagingStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            stagingStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

        ])

        // Wire up tag chips scroll view
        tagChipsScrollView.addSubview(tagChipsStack)
        NSLayoutConstraint.activate([
            tagChipsStack.leadingAnchor.constraint(equalTo: tagChipsScrollView.contentLayoutGuide.leadingAnchor),
            tagChipsStack.trailingAnchor.constraint(equalTo: tagChipsScrollView.contentLayoutGuide.trailingAnchor),
            tagChipsStack.topAnchor.constraint(equalTo: tagChipsScrollView.contentLayoutGuide.topAnchor),
            tagChipsStack.bottomAnchor.constraint(equalTo: tagChipsScrollView.contentLayoutGuide.bottomAnchor),
            tagChipsStack.widthAnchor.constraint(equalTo: tagChipsScrollView.frameLayoutGuide.widthAnchor),
            tagListHeightConstraint,
        ])

        // Show loading placeholder until tags arrive
        tagChipsStack.addArrangedSubview(tagsLoadingLabel)

        saveButton.addTarget(self, action: #selector(saveCredentials), for: .touchUpInside)
        confirmSaveButton.addTarget(self, action: #selector(confirmSave), for: .touchUpInside)
        tagsField.delegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // Pre-fill if values exist
        urlField.text      = storedURL
        usernameField.text = storedUsername
        passwordField.text = storedPassword
    }

    private func makeField(_ field: UITextField,
                           placeholder: String,
                           keyboard: UIKeyboardType = .default,
                           secure: Bool = false) -> UITextField {
        field.placeholder         = placeholder
        field.borderStyle         = .roundedRect
        field.keyboardType        = keyboard
        field.isSecureTextEntry   = secure
        field.autocorrectionType  = .no
        field.autocapitalizationType = .none
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return field
    }

    // MARK: – Mode switching

    /// Spinner shown while we extract the URL from the share payload.
    private func showExtractingMode() {
        subtitleLabel.text = L("share.extracting.subtitle")
        stagingStack.isHidden  = true
        settingsStack.isHidden = true
        activityIndicator.isHidden = false
        statusLabel.isHidden   = false
        statusLabel.text       = ""
        activityIndicator.startAnimating()
        containerHeightConstraint?.constant = 220
    }

    /// Shown after URL extraction: let the user add tags before saving.
    private func showStagingMode(url: String) {
        pendingURL = url
        subtitleLabel.text    = L("share.staging.subtitle")
        let display = url.count > 60 ? String(url.prefix(57)) + "…" : url
        urlPreviewLabel.text  = display
        tagsField.text        = ""
        selectedTagIds        = []
        stagingStack.isHidden  = false
        settingsStack.isHidden = true
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
        statusLabel.isHidden   = true
        containerHeightConstraint?.constant = stagingHeight

        // Load existing tags in the background and populate the chips row
        Task { await loadTagChips() }
    }

    /// Staging for shared files: name or count plus total size, then the same tag tree.
    private func showStagingMode(files: [SharedFile]) {
        pendingFiles = files
        pendingURL = ""
        subtitleLabel.text = L("share.files.subtitle")
        let size = ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file)
        if files.count == 1, let file = files.first {
            urlPreviewLabel.text = "\(file.name) · \(size)"
        } else {
            let count = String(format: L("share.files.count"), files.count)
            urlPreviewLabel.text = String(format: L("share.files.summary"), count, size)
        }
        tagsField.text        = ""
        selectedTagIds        = []
        stagingStack.isHidden  = false
        settingsStack.isHidden = true
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
        statusLabel.isHidden   = true
        containerHeightConstraint?.constant = stagingHeight

        Task { await loadTagChips() }
    }

    private func showSavingMode() {
        subtitleLabel.text = L("share.saving.subtitle")
        stagingStack.isHidden  = true
        settingsStack.isHidden = true
        activityIndicator.isHidden = false
        statusLabel.isHidden = false
        activityIndicator.startAnimating()
        containerHeightConstraint?.constant = 220
    }

    private func showSettingsMode() {
        subtitleLabel.text = L("share.settings.subtitle")
        stagingStack.isHidden  = true
        settingsStack.isHidden = false
        activityIndicator.isHidden = true
        statusLabel.isHidden = true
        containerHeightConstraint?.constant = 340
    }

    // MARK: – Settings actions

    @objc private func saveCredentials() {
        let url  = urlField.text ?? ""
        let user = usernameField.text ?? ""
        let pass = passwordField.text ?? ""

        guard !url.isEmpty, !user.isEmpty, !pass.isEmpty else {
            let alert = UIAlertController(title: L("share.settings.missingFieldsTitle"),
                                          message: L("share.settings.missingFieldsMessage"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("common.ok"), style: .default))
            present(alert, animated: true)
            return
        }

        storedURL      = url
        storedUsername = user
        storedPassword = pass

        urlField.resignFirstResponder()
        usernameField.resignFirstResponder()
        passwordField.resignFirstResponder()

        showSavingMode()
        extractContent()
    }

    // MARK: – URL extraction

    /// A web link is saved as an article (as before); without one, shared files
    /// (photos, videos, audio, PDFs, other documents) go into "Merlin Dateien".
    private func extractContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError(L("share.result.errorReadContent"))
            return
        }
        Task {
            if let url = await findURL(in: items) {
                showStagingMode(url: url)
                return
            }
            let hasFiles = items.flatMap { $0.attachments ?? [] }.contains { Self.fileTypeIdentifier(of: $0) != nil }
            guard hasFiles else {
                showError(L("share.result.errorNoUrl"))
                return
            }
            if keychainRead(.backendKind) == "standalone" {
                showError(L("share.files.errorStandalone"))
                return
            }
            let files = await findFiles(in: items)
            if files.isEmpty {
                showError(L("share.files.errorReadFile"))
            } else {
                showStagingMode(files: files)
            }
        }
    }

    // MARK: – File extraction

    private func findFiles(in items: [NSExtensionItem]) async -> [SharedFile] {
        var files: [SharedFile] = []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            guard let typeIdentifier = Self.fileTypeIdentifier(of: provider) else { continue }
            if let file = await loadFile(from: provider, typeIdentifier: typeIdentifier) {
                files.append(file)
            }
        }
        return files
    }

    /// The best file representation of a provider (Apple lists the original
    /// first, e.g. HEIC before JPEG). Web links and plain text are left out;
    /// text counts only when it is a real file (from the Files app).
    private nonisolated static func fileTypeIdentifier(of provider: NSItemProvider) -> String? {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let isFile = types.contains { $0.conforms(to: .fileURL) }
        return types.first { type in
            guard type.conforms(to: .data), !type.conforms(to: .url) else { return false }
            return isFile || !type.conforms(to: .plainText)
        }?.identifier
    }

    private func loadFile(from provider: NSItemProvider, typeIdentifier: String) async -> SharedFile? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                // The file only exists until this handler returns: copy it first.
                let file = url.flatMap {
                    Self.copyToTemporaryFolder($0, suggestedName: suggestedName, typeIdentifier: typeIdentifier)
                }
                continuation.resume(returning: file)
            }
        }
    }

    private nonisolated static func copyToTemporaryFolder(_ source: URL, suggestedName: String?,
                                                          typeIdentifier: String) -> SharedFile? {
        let type = UTType(typeIdentifier)
        let ext = source.pathExtension.isEmpty ? (type?.preferredFilenameExtension ?? "") : source.pathExtension
        var name = suggestedName.flatMap { $0.isEmpty ? nil : $0 } ?? source.deletingPathExtension().lastPathComponent
        name = name.replacingOccurrences(of: "/", with: "-")
        if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
            name += "." + ext
        }
        let folder = shareTemporaryFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: target)
            let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType
                ?? type?.preferredMIMEType
                ?? "application/octet-stream"
            return SharedFile(localURL: target, name: name, mimeType: mimeType, size: size)
        } catch {
            return nil
        }
    }

    private nonisolated static var shareTemporaryFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("merlin-share", isDirectory: true)
    }

    private func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: Self.shareTemporaryFolder)
    }

    /// Two-pass search across all NSItemProviders.
    /// Pass 1: every provider that advertises UTType.url — accepts both URL and String payloads.
    /// Pass 2: every provider with plain text — extracts the first http(s) URL from the string.
    /// Trying all providers (not just the first match) handles apps that advertise a URL type
    /// but return nil data, while a later provider or the text representation succeeds.
    private func findURL(in items: [NSExtensionItem]) async -> String? {
        let providers = items.flatMap { $0.attachments ?? [] }

        // Pass 1 – UTType.url providers
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURLItem(from: provider) { return url }
        }

        // Pass 2 – plain-text providers (URL embedded in text)
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let url = await loadTextURLItem(from: provider) { return url }
        }

        return nil
    }

    /// Loads a UTType.url item and returns the URL string.
    /// Accepts both `URL` and `String` payloads — some apps return a String instead of URL.
    private func loadURLItem(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { data, _ in
                if let url = data as? URL {
                    // Lokale Datei-URLs (z. B. eine PDF aus "Dateien") sind für den Server wertlos –
                    // nur Links auf Webseiten/PDFs im Netz werden gespeichert.
                    continuation.resume(returning: url.isFileURL ? nil : url.absoluteString)
                } else if let str = data as? String, !str.isEmpty {
                    continuation.resume(returning: str)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Loads a plain-text item and extracts the first http(s) URL it contains.
    private func loadTextURLItem(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                let result = (data as? String).flatMap { Self.extractFirstURL(from: $0) }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: – URL extraction helper

    /// Finds the first http/https URL anywhere in a string.
    private nonisolated static func extractFirstURL(from text: String) -> String? {
        // Use NSDataDetector which handles all URL formats correctly
        let types: NSTextCheckingResult.CheckingType = .link
        guard let detector = try? NSDataDetector(types: types.rawValue) else {
            // Fallback: simple regex
            let pattern = #"https?://[^\s]+"#
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, options: [], range: range)
        for match in matches {
            guard let url = match.url,
                  let scheme = url.scheme,
                  scheme == "http" || scheme == "https" else { continue }
            return url.absoluteString
        }
        return nil
    }

    // MARK: – Confirm save action

    @objc private func confirmSave() {
        guard !pendingURL.isEmpty || !pendingFiles.isEmpty else { done(); return }
        tagsField.resignFirstResponder()
        // New tag names the user typed (for creation)
        let newNames = (tagsField.text ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let url      = pendingURL
        let files    = pendingFiles
        let existing = selectedTagIds  // chip selections
        if files.isEmpty { showSavingMode() } else { showUploadingMode() }
        Task {
            // Resolve typed names → IDs (create if necessary)
            let newIds = newNames.isEmpty ? [] : await resolveTagIds(for: newNames)
            // Merge with chip-selected IDs; dedup
            let allIds = Array(existing.union(newIds))
            if files.isEmpty {
                await saveURL(url, tagIds: allIds)
            } else {
                await saveFiles(files, tagIds: allIds)
            }
        }
    }

    // MARK: – Tag tree (staging mode)

    /// Sheet height in staging mode: the base layout (sized for one row of
    /// tags) plus the extra rows of the tag list.
    private var stagingHeight: CGFloat {
        340 + tagListHeightConstraint.constant - Self.tagRowHeight
    }

    /// Tags in tree order (parents before children, siblings by name) with
    /// their depth. A tag whose parent is missing counts as top level.
    private func tagTreeRows() -> [(tag: ShareTag, depth: Int)] {
        let ids = Set(availableTags.map(\.id))
        var children: [Int?: [ShareTag]] = [:]
        for tag in availableTags {
            let parent = tag.parentId.flatMap { ids.contains($0) ? $0 : nil }
            children[parent, default: []].append(tag)
        }
        var rows: [(tag: ShareTag, depth: Int)] = []
        var seen = Set<Int>()
        func walk(_ parent: Int?, _ depth: Int) {
            let sorted = (children[parent] ?? []).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            for tag in sorted where seen.insert(tag.id).inserted {
                rows.append((tag: tag, depth: depth))
                walk(tag.id, depth + 1)
            }
        }
        walk(nil, 0)
        return rows
    }

    /// Parent tag, its parent, … of `id`.
    private func ancestorIds(of id: Int) -> Set<Int> {
        let byId = Dictionary(availableTags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result = Set<Int>()
        var parent = byId[id]?.parentId.flatMap { byId[$0] }
        while let p = parent, p.id != id, result.insert(p.id).inserted {
            parent = p.parentId.flatMap { byId[$0] }
        }
        return result
    }

    /// Sub-tags of `id` at any depth.
    private func descendantIds(of id: Int) -> Set<Int> {
        var result = Set<Int>()
        var queue = availableTags.filter { $0.parentId == id }
        while !queue.isEmpty {
            let tag = queue.removeFirst()
            guard tag.id != id, result.insert(tag.id).inserted else { continue }
            queue.append(contentsOf: availableTags.filter { $0.parentId == tag.id })
        }
        return result
    }

    /// Fetches all tags from the server and builds the horizontal chip row.
    @MainActor
    private func loadTagChips() async {
        let base  = storedURL
        let token = Data("\(storedUsername):\(storedPassword)".utf8).base64EncodedString()

        guard let tagsURL = URL(string: "\(base)\(apiPrefix)/tags") else { return }
        var req = URLRequest(url: tagsURL, timeoutInterval: 10)
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

        struct TagDTO: Decodable { let id: Int; let name: String; let parentId: Int? }
        let fetched: [TagDTO]
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            fetched = (try? JSONDecoder().decode([TagDTO].self, from: data)) ?? []
        } catch {
            fetched = []
        }

        availableTags = fetched.map { ShareTag(id: $0.id, name: $0.name, parentId: $0.parentId) }

        // Rebuild the tag list on the main thread
        for view in tagChipsStack.arrangedSubviews { tagChipsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        tagButtons = [:]

        if availableTags.isEmpty {
            let none = UILabel()
            none.text = L("share.staging.noTags")
            none.font = .systemFont(ofSize: 13)
            none.textColor = .secondaryLabel
            tagChipsStack.addArrangedSubview(none)
        } else {
            for row in tagTreeRows() {
                let btn = makeTagRowButton(tag: row.tag, depth: row.depth)
                tagButtons[row.tag.id] = btn
                tagChipsStack.addArrangedSubview(btn)
            }
        }

        // Grow the sheet with the list, up to maxVisibleTagRows; beyond that it scrolls.
        let rowCount = max(1, min(tagButtons.count, Self.maxVisibleTagRows))
        tagListHeightConstraint.constant = CGFloat(rowCount) * Self.tagRowHeight
            + CGFloat(rowCount - 1) * tagChipsStack.spacing
        if !stagingStack.isHidden {
            containerHeightConstraint?.constant = stagingHeight
            UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() }
        }
    }

    /// One row of the tag tree: checkmark circle and name, indented by depth.
    private func makeTagRowButton(tag: ShareTag, depth: Int) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = tag.name
        config.imagePadding = 8
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4 + CGFloat(depth) * 22, bottom: 0, trailing: 4)
        config.titleLineBreakMode = .byTruncatingTail
        let btn = UIButton(configuration: config)
        btn.tag = tag.id
        btn.contentHorizontalAlignment = .leading
        btn.heightAnchor.constraint(equalToConstant: Self.tagRowHeight).isActive = true
        btn.addTarget(self, action: #selector(chipTapped(_:)), for: .touchUpInside)
        applySelectionStyle(to: btn, selected: selectedTagIds.contains(tag.id))
        return btn
    }

    private func applySelectionStyle(to button: UIButton, selected: Bool) {
        var config = button.configuration ?? .plain()
        config.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        config.baseForegroundColor = selected ? .systemBlue : .label
        button.configuration = config
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    /// Selecting a sub-tag also selects its parent tags; deselecting a tag
    /// also deselects its sub-tags, so a sub-tag never stays selected without
    /// its parent.
    @objc private func chipTapped(_ sender: UIButton) {
        let tagId = sender.tag
        if selectedTagIds.contains(tagId) {
            selectedTagIds.subtract(descendantIds(of: tagId).union([tagId]))
        } else {
            selectedTagIds.formUnion(ancestorIds(of: tagId).union([tagId]))
        }
        for (id, button) in tagButtons {
            applySelectionStyle(to: button, selected: selectedTagIds.contains(id))
        }
    }

    // MARK: – Tag resolution

    /// Resolves typed tag names to IDs.
    /// Uses the `availableTags` cache populated by `loadTagChips`. If that fetch
    /// hasn't finished yet (slow server), we wait for it here before proceeding
    /// so we don't accidentally create duplicate tags.
    /// Creates tags that don't exist yet via POST.
    @MainActor
    private func resolveTagIds(for names: [String]) async -> [Int] {
        if availableTags.isEmpty { await loadTagChips() }
        let base   = storedURL
        let token  = Data("\(storedUsername):\(storedPassword)".utf8).base64EncodedString()
        let cached = availableTags

        var ids: [Int] = []
        for name in names {
            if let match = cached.first(where: { $0.name.lowercased() == name.lowercased() }) {
                ids.append(match.id)
            } else if let newId = await createTagAsync(name: name, token: token, base: base) {
                ids.append(newId)
            }
        }
        return ids
    }

    private func createTagAsync(name: String, token: String, base: String) async -> Int? {
        guard let url = URL(string: "\(base)\(apiPrefix)/tags"),
              let body = try? JSONEncoder().encode(["name": name]) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        struct TagDTO: Decodable { let id: Int }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try? JSONDecoder().decode(TagDTO.self, from: data).id
        } catch {
            return nil
        }
    }

    // MARK: – API call

    private func saveURL(_ urlString: String, tagIds: [Int] = []) async {
        // Build URL; append tagIds as query params (tagIds[]=1&tagIds[]=2) so they
        // are always readable via getParam() regardless of Nextcloud version.
        guard var components = URLComponents(string: "\(storedURL)\(apiPrefix)/articles") else {
            showError("Invalid Nextcloud URL."); return
        }
        if !tagIds.isEmpty {
            components.queryItems = tagIds.map { URLQueryItem(name: "tagIds[]", value: "\($0)") }
        }
        guard let apiURL = components.url else {
            showError("Invalid Nextcloud URL."); return
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["url": urlString]) else {
            showError("Failed to encode request."); return
        }

        let token = Data("\(storedUsername):\(storedPassword)".utf8).base64EncodedString()
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                showError(L("share.result.errorNoResponse")); return
            }
            switch http.statusCode {
            case 200...299:
                showSuccess(L("share.result.successTitle"))
            case 401:
                showError(L("share.result.errorAuthFailed"))
            case 404:
                showError(L("share.result.errorAppNotFound"))
            case 429:
                showRetry(L("share.result.errorRateLimited"))
            default:
                // Try to surface the server's own error description to aid diagnosis.
                var detail = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let msg = json["error"] as? String, !msg.isEmpty {
                    detail = "\n\(msg)"
                }
                showError(String(format: L("share.result.errorServerCode"), http.statusCode) + detail)
            }
        } catch {
            showError(String(format: L("share.result.errorNetwork"), error.localizedDescription))
        }
    }

    // MARK: – File upload

    private func showUploadingMode() {
        showSavingMode()
        subtitleLabel.text = L("share.files.uploadingSubtitle")
        progressView.progress = 0
        progressView.isHidden = false
    }

    private func updateUploadProgress(index: Int, total: Int, fraction: Double) {
        let percent = NumberFormatter.localizedString(from: NSNumber(value: min(1, max(0, fraction))), number: .percent)
        statusLabel.text = String(format: L("share.files.progress"), "\(index + 1)", "\(total)", percent)
        progressView.setProgress(Float(fraction), animated: true)
    }

    private func saveFiles(_ files: [SharedFile], tagIds: [Int]) async {
        let token = Data("\(storedUsername):\(storedPassword)".utf8).base64EncodedString()
        let uploader = FileUploader(baseURL: storedURL, apiPrefix: apiPrefix, authorization: "Basic \(token)")
        let totalBytes = Double(max(1, files.reduce(0) { $0 + $1.size }))
        var uploadedBytes: Int64 = 0

        for (index, file) in files.enumerated() {
            let before = Double(uploadedBytes)
            updateUploadProgress(index: index, total: files.count, fraction: before / totalBytes)
            do {
                try await uploader.upload(file, tagIds: tagIds) { [weak self] fraction in
                    Task { @MainActor in
                        self?.updateUploadProgress(index: index, total: files.count,
                                                   fraction: (before + fraction * Double(file.size)) / totalBytes)
                    }
                }
            } catch {
                removeTemporaryFiles()
                showUploadError(error, file: file)
                return
            }
            uploadedBytes += file.size
        }
        removeTemporaryFiles()
        showSuccess(L("share.result.successTitle"))
    }

    private func showUploadError(_ error: Error, file: SharedFile) {
        progressView.isHidden = true
        let failed = String(format: L("share.files.errorUpload"), file.name)
        switch error {
        case FileUploader.UploadError.http(401, _):
            showError(L("share.result.errorAuthFailed"))
        case FileUploader.UploadError.http(429, _):
            showError(L("share.result.errorRateLimited"))
        case FileUploader.UploadError.http(let code, let message):
            let detail = message.map { "\n" + $0 } ?? ""
            showError(failed + "\n" + String(format: L("share.result.errorServerCode"), code) + detail)
        case FileUploader.UploadError.unreadableFile:
            showError(L("share.files.errorReadFile"))
        case FileUploader.UploadError.invalidResponse:
            showError(failed + "\n" + L("share.result.errorNoResponse"))
        default:
            showError(failed + "\n" + String(format: L("share.result.errorNetwork"), error.localizedDescription))
        }
    }

    // MARK: – State display

    private func showSuccess(_ message: String) {
        activityIndicator.stopAnimating()
        done()
    }

    private func showError(_ message: String) {
        activityIndicator.stopAnimating()
        iconView.image     = UIImage(systemName: "xmark.circle.fill")
        iconView.tintColor = .systemRed
        subtitleLabel.text = L("share.result.errorTitle")
        statusLabel.text   = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.done()
        }
    }

    /// Called on HTTP 429. Shows a short message, then restores the staging
    /// screen so the user can tap "Save to Merlin" again without re-sharing.
    private func showRetry(_ message: String) {
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
        iconView.image     = UIImage(systemName: "clock.badge.exclamationmark.fill")
        iconView.tintColor = .systemOrange
        subtitleLabel.text = L("share.rateLimited.subtitle")
        statusLabel.isHidden = false
        statusLabel.text   = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            // Restore staging UI without re-fetching tags
            self.subtitleLabel.text                  = L("share.staging.subtitle")
            self.stagingStack.isHidden               = false
            self.activityIndicator.isHidden          = true
            self.statusLabel.isHidden                = true
            self.iconView.image                      = UIImage(named: "MerlinLogo",
                                                             in: Bundle(for: ShareViewController.self),
                                                             compatibleWith: nil)
            self.iconView.tintColor                  = .label
            self.containerHeightConstraint?.constant  = self.stagingHeight
        }
    }

    @objc private func done() {
        guard !isDone else { return }
        isDone = true
        removeTemporaryFiles()
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func backgroundTapped() {
        view.endEditing(true)
    }
}

// MARK: – UITextFieldDelegate

extension ShareViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField == tagsField {
            confirmSave()
        } else {
            textField.resignFirstResponder()
        }
        return true
    }
}
