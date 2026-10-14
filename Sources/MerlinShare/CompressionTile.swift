import UIKit

/// One choice in the share sheet's image compression row: preview crop,
/// title and resulting size. Shows a spinner until the level is computed.
final class CompressionTile: UIControl {
    let level: ImageCompression

    private let imageView: UIImageView = {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.layer.cornerRadius = 8
        v.backgroundColor = .secondarySystemFill
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.hidesWhenStopped = true
        return s
    }()
    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textAlignment = .center
        l.numberOfLines = 2
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.8
        return l
    }()
    private let sizeLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.text = "…"
        return l
    }()

    static let height: CGFloat = 140

    init(level: ImageCompression, title: String) {
        self.level = level
        super.init(frame: .zero)
        titleLabel.text = title
        layer.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [imageView, titleLabel, sizeLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        imageView.addSubview(spinner)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            imageView.heightAnchor.constraint(equalToConstant: 72),
            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        ])
        spinner.startAnimating()

        isAccessibilityElement = true
        updateSelectionStyle()
        // CGColor borders don't follow dark mode on their own.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (tile: CompressionTile, _: UITraitCollection) in
            tile.updateSelectionStyle()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isSelected: Bool {
        didSet { updateSelectionStyle() }
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// Shows the computed level; `nil` keeps the spinner.
    func show(_ option: CompressionOption?) {
        guard let option else {
            imageView.image = nil
            sizeLabel.text = "…"
            spinner.startAnimating()
            updateAccessibility()
            return
        }
        spinner.stopAnimating()
        imageView.image = option.preview.flatMap { UIImage(data: $0) }
        sizeLabel.text = ByteCountFormatter.string(fromByteCount: option.totalSize, countStyle: .file)
        updateAccessibility()
    }

    private func updateSelectionStyle() {
        layer.borderWidth = isSelected ? 2 : 1
        layer.borderColor = (isSelected ? tintColor : UIColor.separator).cgColor
        backgroundColor = isSelected ? tintColor.withAlphaComponent(0.08) : .clear
        updateAccessibility()
    }

    private func updateAccessibility() {
        accessibilityLabel = [titleLabel.text, sizeLabel.text].compactMap { $0 }.joined(separator: ", ")
        accessibilityTraits = isSelected ? [.button, .selected] : .button
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateSelectionStyle()
    }
}
