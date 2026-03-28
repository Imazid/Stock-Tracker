//
//  NewsAdBannerView.swift
//  Stock Tracker
//
//  AdMob Native Ad integration — displayed in the news feed as a seamless
//  card that matches NewsCompactCard visually.
//  Hidden automatically for Pro / Black subscribers (SubscriptionTier.isAdFree).
//
//  ── SETUP (one-time) ──────────────────────────────────────────────────────
//  1. Add the GoogleMobileAds Swift Package in Xcode:
//       File ▸ Add Package Dependencies…
//       URL: https://github.com/googleads/swift-package-manager-google-mobile-ads.git
//       Version: Up To Next Major (13.x)
//
//  2. Stock-Tracker-Info.plist already has GADApplicationIdentifier set to
//     Google's test App ID. Replace it with your real AdMob App ID before
//     going to production.
//
//  3. Replace kNewsNativeAdUnitID below with your real NATIVE Ad Unit ID
//     from the AdMob console (create a "Native" ad unit, not Banner).
//     The value below is Google's official test native ID.
//  ─────────────────────────────────────────────────────────────────────────

import SwiftUI
import Combine
import OSLog

// Replace with your real Native Ad Unit ID from the AdMob console.
private let kNewsNativeAdUnitID = "ca-app-pub-3940256099942544/3986624511"

#if canImport(GoogleMobileAds)
import GoogleMobileAds

// MARK: - Native Ad Loader

final class NewsNativeAdLoader: NSObject, ObservableObject {
    @Published var nativeAd: NativeAd?
    private var adLoader: AdLoader?

    func load() {
        guard adLoader == nil else { return }
        let rootVC = UIApplication.shared
            .connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first
        let loader = AdLoader(
            adUnitID: kNewsNativeAdUnitID,
            rootViewController: rootVC,
            adTypes: [.native],
            options: nil
        )
        loader.delegate = self
        loader.load(Request())
        self.adLoader = loader
    }
}

extension NewsNativeAdLoader: NativeAdLoaderDelegate {
    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        DispatchQueue.main.async { self.nativeAd = nativeAd }
        nativeAd.delegate = self
        AppLogger.api.debug("AdMob native ad loaded")
    }

    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        AppLogger.api.warning("AdMob native ad failed: \(error.localizedDescription)")
    }
}

extension NewsNativeAdLoader: NativeAdDelegate {}

// MARK: - UIKit Native Ad View (styled to match NewsCompactCard exactly)

/// A NativeAdView subclass whose layout mirrors NewsCompactCard.
/// Adapts based on available display size at layout time:
///   - ≤120×120 pt → compact: icon UIImageView + text (MediaView hidden)
///   - >120×120 pt → expanded: MediaView on top + text below (icon hidden)
/// MediaView lives outside the main stack to avoid constraint conflicts
/// with UIStackView's hidden-view compression.
final class StockNativeAdView: NativeAdView {
    private let iconImageView = UIImageView()
    private let adMediaView  = MediaView()
    private let headlineLabel  = UILabel()
    private let advertiserLabel = UILabel()
    private let adBadge = UILabel()
    private let bodyLabel = UILabel()
    private var mainStack: UIStackView!

    /// Threshold in points — above this in both width and height, use MediaView.
    private let sizeThreshold: CGFloat = 120

    /// Tracks current mode so we don't re-toggle on every layout pass.
    private var isUsingMediaView = false

    // Switchable constraints
    private var compactTopConstraint: NSLayoutConstraint!   // mainStack.top → self.top
    private var expandedTopConstraint: NSLayoutConstraint!  // mainStack.top → mediaView.bottom
    private var mediaTopConstraint: NSLayoutConstraint!
    private var mediaHeightConstraint: NSLayoutConstraint!
    private var mediaLeadingConstraint: NSLayoutConstraint!
    private var mediaTrailingConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func setupLayout() {
        backgroundColor = .clear

        // 90×90 icon thumbnail (matches NewsCompactCard)
        iconImageView.contentMode = .scaleAspectFill
        iconImageView.clipsToBounds = true
        iconImageView.layer.cornerRadius = 14
        iconImageView.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.10)
        iconImageView.tintColor = UIColor.systemBlue
        iconImageView.image = UIImage(systemName: "chart.bar.fill")
        iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 28, weight: .light
        )
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        // Media view — added as a direct subview, NOT inside the stack
        adMediaView.contentMode = .scaleAspectFill
        adMediaView.clipsToBounds = true
        adMediaView.layer.cornerRadius = 12
        adMediaView.translatesAutoresizingMaskIntoConstraints = false
        adMediaView.isHidden = true
        addSubview(adMediaView)

        // Headline — matches .subheadline.bold()
        headlineLabel.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        headlineLabel.numberOfLines = 2
        headlineLabel.textColor = .label
        headlineLabel.translatesAutoresizingMaskIntoConstraints = false

        // Advertiser — matches source name in .caption.bold() blue
        advertiserLabel.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        advertiserLabel.textColor = .systemBlue
        advertiserLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        advertiserLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        advertiserLabel.translatesAutoresizingMaskIntoConstraints = false

        // Separator dot
        let dotLabel = UILabel()
        dotLabel.text = "·"
        dotLabel.font = UIFont.systemFont(ofSize: 12)
        dotLabel.textColor = .secondaryLabel
        dotLabel.setContentHuggingPriority(.required, for: .horizontal)
        dotLabel.translatesAutoresizingMaskIntoConstraints = false

        // "Ad" badge (matches time label slot)
        adBadge.text = " Ad "
        adBadge.font = UIFont.systemFont(ofSize: 9, weight: .semibold)
        adBadge.textColor = UIColor.systemBlue
        adBadge.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        adBadge.layer.cornerRadius = 4
        adBadge.layer.masksToBounds = true
        adBadge.setContentHuggingPriority(.required, for: .horizontal)
        adBadge.translatesAutoresizingMaskIntoConstraints = false

        // Body — matches .caption in .secondaryText
        bodyLabel.font = UIFont.systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 2
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        // Source row: [Advertiser] · [Ad]
        let sourceRow = UIStackView(arrangedSubviews: [advertiserLabel, dotLabel, adBadge])
        sourceRow.axis = .horizontal
        sourceRow.spacing = 6
        sourceRow.alignment = .center
        sourceRow.translatesAutoresizingMaskIntoConstraints = false

        // Text column
        let textStack = UIStackView(arrangedSubviews: [headlineLabel, sourceRow, bodyLabel])
        textStack.axis = .vertical
        textStack.spacing = 6
        textStack.alignment = .leading
        textStack.translatesAutoresizingMaskIntoConstraints = false

        // Main row: [icon] [text]
        mainStack = UIStackView(arrangedSubviews: [iconImageView, textStack])
        mainStack.axis = .horizontal
        mainStack.spacing = 14
        mainStack.alignment = .top
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        // Prepare switchable constraints (inactive until needed)
        compactTopConstraint = mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        expandedTopConstraint = mainStack.topAnchor.constraint(equalTo: adMediaView.bottomAnchor, constant: 10)

        mediaTopConstraint = adMediaView.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        mediaLeadingConstraint = adMediaView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        mediaTrailingConstraint = adMediaView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        mediaHeightConstraint = adMediaView.heightAnchor.constraint(equalToConstant: 120)

        // Always-on constraints
        NSLayoutConstraint.activate([
            iconImageView.widthAnchor.constraint(equalToConstant: 90),
            iconImageView.heightAnchor.constraint(equalToConstant: 90),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            mainStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
            // Default: compact mode
            compactTopConstraint,
        ])

        // Wire NativeAdView outlets so Google tracks clicks correctly
        self.headlineView   = headlineLabel
        self.bodyView       = bodyLabel
        self.iconView       = iconImageView
        self.advertiserView = advertiserLabel
        self.mediaView      = adMediaView
    }

    // MARK: - Size-based switching

    override func layoutSubviews() {
        super.layoutSubviews()
        let useMedia = bounds.width > sizeThreshold && bounds.height > sizeThreshold
        guard useMedia != isUsingMediaView else { return }
        isUsingMediaView = useMedia

        if useMedia {
            // Switch to expanded: show media on top, hide icon
            compactTopConstraint.isActive = false
            NSLayoutConstraint.activate([
                mediaTopConstraint, mediaLeadingConstraint,
                mediaTrailingConstraint, mediaHeightConstraint,
                expandedTopConstraint,
            ])
            adMediaView.isHidden = false
            iconImageView.isHidden = true
        } else {
            // Switch to compact: hide media, show icon
            NSLayoutConstraint.deactivate([
                mediaTopConstraint, mediaLeadingConstraint,
                mediaTrailingConstraint, mediaHeightConstraint,
                expandedTopConstraint,
            ])
            compactTopConstraint.isActive = true
            adMediaView.isHidden = true
            iconImageView.isHidden = false
        }
    }

    // MARK: - Populate

    func populate(with ad: NativeAd) {
        self.nativeAd = ad
        headlineLabel.text   = ad.headline
        bodyLabel.text       = ad.body
        advertiserLabel.text = ad.advertiser ?? ad.store ?? "Sponsored"
        if let icon = ad.icon?.image {
            iconImageView.image = icon
            iconImageView.contentMode = .scaleAspectFill
        }
    }
}

// MARK: - UIViewRepresentable bridge

private struct StockNativeAdUIView: UIViewRepresentable {
    let nativeAd: NativeAd

    func makeUIView(context: Context) -> StockNativeAdView {
        let view = StockNativeAdView()
        view.populate(with: nativeAd)
        return view
    }

    func updateUIView(_ uiView: StockNativeAdView, context: Context) {}
}

// MARK: - SwiftUI card (drop-in replacement for NewsAdBannerCard)

/// Renders a native ad styled identically to NewsCompactCard.
struct NewsAdBannerCard: View {
    @StateObject private var loader = NewsNativeAdLoader()
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        Group {
            if let ad = loader.nativeAd {
                StockNativeAdUIView(nativeAd: ad)
                    .frame(minHeight: 114)
                    .background(theme.glassBackground)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            } else {
                // Skeleton placeholder — same dimensions as NewsCompactCard
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.glassBackground.opacity(0.5))
                    .frame(height: 114)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.cardBorder, lineWidth: 1)
                    )
            }
        }
        .onAppear { loader.load() }
    }
}

#else

// MARK: - Stub (SDK not installed — compiles cleanly, shows nothing)

struct NewsAdBannerCard: View {
    var body: some View { EmptyView() }
}

#endif

// MARK: - SDK Initialiser (call once at app launch)

enum AdMobInitializer {
    static func start() {
        #if canImport(GoogleMobileAds)
        MobileAds.shared.start(completionHandler: nil)
        #endif
    }
}
