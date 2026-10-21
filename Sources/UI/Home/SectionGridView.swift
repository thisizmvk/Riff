import SwiftUI

/// Full-shelf page reached from a rail header's "More" button — the
/// whole section as a wrapping tile grid instead of the one-row
/// carousel. Pure presentation: the items were already fetched for the
/// rail, so landing here costs no network.
struct SectionGridView: View {
    @Environment(AppEnvironment.self) private var env
    let section: HomeSection

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                backButton
                Text(section.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        ThumbnailButton(item: item)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, env.player.hasTrack ? 96 : 24)
        }
        .background(Theme.Bg.base.ignoresSafeArea())
        // CRITICAL — same rule as DetailView: every pushed page must
        // suppress NavigationStack's automatic back-button toolbar item
        // at the source, or the NSToolbar duplicate-identifier crash
        // returns (multiple mounted tab stacks, one toolbar).
        .navigationBarBackButtonHidden(true)
    }

    private func goBack() {
        switch env.activeTab {
        case .home:    if !env.homeNavPath.isEmpty    { env.homeNavPath.removeLast() }
        case .explore: if !env.exploreNavPath.isEmpty { env.exploreNavPath.removeLast() }
        case .search:  if !env.searchNavPath.isEmpty  { env.searchNavPath.removeLast() }
        case .library: if !env.libraryNavPath.isEmpty { env.libraryNavPath.removeLast() }
        }
    }

    private var backButton: some View {
        Button(action: goBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("Back")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Theme.Fill.strong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        .accessibilityLabel("Back")
    }
}
