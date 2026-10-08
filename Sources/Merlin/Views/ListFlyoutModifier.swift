import SwiftUI
import UIKit

// MARK: – UIKit-Wischgeste (am UIWindow — blockiert keine Scrollgesten)

/// Unsichtbare Hilfsview, die beim Einbetten in die View-Hierarchie einen
/// UIScreenEdgePanGestureRecognizer direkt ans UIWindow hängt.
/// Weil der Recognizer auf dem Window sitzt, braucht keine View Touches
/// abzufangen — Scrollgesten werden nicht blockiert.
private final class LeftEdgePanInstaller: UIView {
    var onTriggered: (() -> Void)?
    var installedRecognizer: UIScreenEdgePanGestureRecognizer?

    /// Delegate-Objekt, das simultane Erkennung erlaubt.
    /// Ohne das scheitert unser Recognizer, sobald der Card-DragGesture
    /// (minimumDistance: 10) als Erster in .began geht und UIKit
    /// alle anderen Recognizer zum Scheitern zwingt.
    private let simultaneousDelegate = SimultaneousGestureDelegate()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Alten Recognizer entfernen
        if let r = installedRecognizer {
            r.view?.removeGestureRecognizer(r)
            installedRecognizer = nil
        }
        // Neuen Recognizer am Window installieren
        guard let window else { return }
        let recognizer = UIScreenEdgePanGestureRecognizer(
            target: self,
            action: #selector(handle(_:))
        )
        recognizer.edges = .left
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = simultaneousDelegate   // ← simultane Erkennung
        window.addGestureRecognizer(recognizer)
        installedRecognizer = recognizer
    }

    @objc private func handle(_ r: UIScreenEdgePanGestureRecognizer) {
        guard r.state == .began else { return }
        onTriggered?()
    }

    // Keine Touches selbst abfangen — alles durchreichen
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Erlaubt unserem Edge-Pan-Recognizer, gleichzeitig mit beliebigen
/// anderen Recognizern (ScrollView, Card-Swipe, …) aktiv zu sein —
/// aber zwingt Swipe-Action-Recognizer auf Table-Zellen dazu, erst auf
/// das *Scheitern* des Edge-Pans zu warten.  Dadurch gilt: startet der
/// Finger am linken Bildschirmrand, öffnet sich nur das Flyout und kein
/// Teilen-Button (analog zu `startLocation.x < 25` im CardView).
private final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        // Unser Edge-Recognizer muss scheitern, bevor ein Pan-Recognizer
        // auf einer Table-Zelle (= Swipe-Action) aktiv werden darf.
        // ScrollView-Pans (scrollen) sind ausgenommen.
        guard other is UIPanGestureRecognizer,
              !(other.view is UIScrollView) else { return false }
        return true
    }
}

private struct LeftEdgePanGestureView: UIViewRepresentable {
    var isEnabled: Bool
    var onTriggered: () -> Void

    func makeUIView(context: Context) -> LeftEdgePanInstaller {
        let view = LeftEdgePanInstaller()
        view.isUserInteractionEnabled = false
        view.onTriggered = onTriggered
        return view
    }

    func updateUIView(_ uiView: LeftEdgePanInstaller, context: Context) {
        uiView.onTriggered = isEnabled ? onTriggered : nil
        uiView.installedRecognizer?.isEnabled = isEnabled
    }
}

// MARK: – Flyout-Modifier

/// Hängt das linke Flyout-Navigationsmenü an jede beliebige View.
/// Einfach `.listFlyout(viewModel:)` auf einen fullscreen-View anwenden.
struct ListFlyoutModifier: ViewModifier {
    let viewModel: ArticlesViewModel
    /// Called after a filter or tag selection so the host view can navigate away (e.g. dismiss the reader).
    var onNavigate: (() -> Void)? = nil

    @State private var showSideMenu:   Bool    = false
    @State private var tagsExpanded:   Bool    = false
    /// Im Menü angezeigte Medienart (Tab). Steht beim Öffnen auf der Gruppe
    /// des aktiven Filters; ein Tab-Wechsel lädt nichts, erst die Zeile.
    @State private var menuGroup:      ContentGroup = .pages
    @State private var safeAreaTop:    CGFloat = 0
    @State private var safeAreaBottom: CGFloat = 0
    @State private var showSettings:   Bool    = false
    @State private var showReminders:  Bool    = false
    /// Tag, dessen „Verschieben nach…“-Sheet offen ist (Kontextmenü am Tag).
    @State private var tagToMove:      Tag?    = nil
    /// Aufgeklappte Eltern-Tags (verschachtelte Tags), kommagetrennte Ids.
    @AppStorage("merlinExpandedTagIds") private var expandedTagIdsRaw: String = ""
    @AppStorage("merlinIsCardView") private var isCardView: Bool = true

    func body(content: Content) -> some View {
        content
            .onAppear {
                let insets = UIApplication.shared
                    .connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.windows.first?.safeAreaInsets
                safeAreaTop    = insets?.top    ?? 44
                safeAreaBottom = insets?.bottom ?? 0
            }
            .sheet(isPresented: $showSettings)  { SettingsView() }
            .sheet(isPresented: $showReminders) { RemindersView() }
            .sheet(item: $tagToMove) { tag in
                MoveTagSheet(tag: tag, tree: viewModel.tagTree) { parentId in
                    Task { await viewModel.moveTag(tag.id, under: parentId) }
                    if let parentId { setExpanded(parentId, true) }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .overlay {
                ZStack {
                    // ── UIKit-Wischzone (linker Rand) ──────────────────────────
                    // allowsHitTesting(false): SwiftUI reicht alle Events durch.
                    // Der UIScreenEdgePanGestureRecognizer sitzt am Window und
                    // feuert unabhängig davon.
                    LeftEdgePanGestureView(isEnabled: !showSideMenu) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                            showSideMenu = true
                        }
                    }
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                    // ── Scrim + Drawer ─────────────────────────────────────────
                    if showSideMenu {
                        Color.black.opacity(0.38)
                            .ignoresSafeArea()
                            .onTapGesture { close() }
                            .transition(.opacity)

                        HStack(spacing: 0) {
                            sideMenuDrawer
                                .frame(width: 300)
                                .ignoresSafeArea(edges: .vertical)
                                .gesture(
                                    DragGesture(minimumDistance: 15, coordinateSpace: .local)
                                        .onEnded { val in
                                            if val.translation.width < -15 { close() }
                                        }
                                )
                            Spacer()
                        }
                        .transition(.move(edge: .leading))
                    }
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: showSideMenu)
            .onChange(of: showSideMenu) { _, isShown in
                if isShown {
                    menuGroup = viewModel.selectedFilter.group
                    expandAncestorsOfSelectedTag()
                }
            }
    }

    // MARK: – Drawer-Inhalt

    private var sideMenuDrawer: some View {
        VStack(spacing: 0) {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Platz für Statusleiste / Dynamic Island
                Color.clear.frame(height: safeAreaTop)

                // ── Filter: Tabs Text/Video/Audio, darunter die
                //    Continue/Unread(/Unseen/Unheard)/Favorites/Archive-Ansichten
                //    der gewählten Medienart ──
                Picker(L("navigationMenu.mediaTypePicker"), selection: $menuGroup) {
                    Text(L("navigationMenu.tab.text")).tag(ContentGroup.pages)
                    Text(L("navigationMenu.tab.video")).tag(ContentGroup.videos)
                    Text(L("navigationMenu.tab.audio")).tag(ContentGroup.audio)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)

                filterSection(group: menuGroup)

                // ── Tags (ausklappbar) ─────────────────────────────────────────
                if !viewModel.allTags.isEmpty {
                    menuDivider

                    // Tags-Header mit Chevron
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            tagsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "tag")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(.primary)
                                .frame(width: 24, alignment: .center)
                            Text(L("navigationMenu.tagsHeader"))
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(tagsExpanded ? 90 : 0))
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Ausgeklappte Tag-Liste als Baum: Unter-Tags eingerückt,
                    // Eltern-Tags mit eigenem Pfeil zum Auf-/Zuklappen. Ein
                    // Tag zeigt auch die Artikel seiner Unter-Tags. Lange
                    // drücken → „Verschieben nach…“.
                    if tagsExpanded {
                        ForEach(visibleTagRows) { row in
                            tagRow(row)
                        }
                        if viewModel.selectedTagId != nil {
                            menuRow(
                                icon: "xmark.circle",
                                label: L("navigationMenu.clearTagFilter"),
                                tint: .red,
                                indented: true
                            ) {
                                Task { await viewModel.selectTag(nil) }
                                close(then: onNavigate)
                            }
                        }
                    }
                }

                menuDivider

                // ── Ansicht ────────────────────────────────────────────────────
                menuRow(
                    icon: isCardView ? "square.grid.2x2.fill" : "rectangle.grid.1x2",
                    label: isCardView ? L("navigationMenu.listView") : L("navigationMenu.cardView"),
                    tint: isCardView ? .accentColor : nil
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { isCardView.toggle() }
                    close()
                }

                menuDivider

                // ── Weiteres ───────────────────────────────────────────────────
                menuRow(icon: "bell", label: L("reminders.list.title")) {
                    close(); showReminders = true
                }
                menuRow(icon: "gearshape", label: L("common.settings")) {
                    close(); showSettings = true
                }
                menuRow(icon: "questionmark.circle", label: L("navigationMenu.appTour")) {
                    close()
                    // Resetting the flag triggers ArticleListView.onChange to re-show the tour
                    UserDefaults.standard.set(false, forKey: "merlin_tour_done")
                }

            }
            .padding(.top, 8)
        }

        // ── Merlin-Logo – immer an der Bildschirmkante sichtbar ───────────
        HStack {
            if let url = Bundle.module.url(forResource: "merlin-logo", withExtension: "png"),
               let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(height: 60)
                    .opacity(0.22)
                    .padding(.leading, 20)
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.bottom, safeAreaBottom)
        .background(Color(.systemBackground))
        } // VStack
        .background(Color(.systemBackground))
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            Color(.separator).frame(width: 0.5)
        }
    }

    // MARK: – Hilfsfunktionen

    @ViewBuilder
    private func menuRow(
        icon: String,
        label: String,
        tint: Color? = nil,
        indented: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(tint ?? .primary)
                    .frame(width: 24, alignment: .center)
                Text(label)
                    .font(.body)
                    .foregroundStyle(tint ?? .primary)
                Spacer()
            }
            .padding(.leading, indented ? 40 : 20)
            .padding(.trailing, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: – Tag-Baum

    private var expandedTagIds: Set<Int> {
        Set(expandedTagIdsRaw.split(separator: ",").compactMap { Int($0) })
    }

    private func setExpanded(_ tagId: Int, _ expanded: Bool) {
        var ids = expandedTagIds
        if expanded { ids.insert(tagId) } else { ids.remove(tagId) }
        expandedTagIdsRaw = ids.sorted().map(String.init).joined(separator: ",")
    }

    /// Der gewählte Tag bleibt sichtbar: seine Eltern-Tags aufklappen.
    private func expandAncestorsOfSelectedTag() {
        guard let selected = viewModel.selectedTagId else { return }
        let byId = Dictionary(viewModel.allTags.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<Int> = [selected]
        var parent = byId[selected]?.parentId
        while let id = parent, seen.insert(id).inserted {
            if !expandedTagIds.contains(id) { setExpanded(id, true) }
            parent = byId[id]?.parentId
        }
    }

    private var visibleTagRows: [TagTree.Row] {
        let tree = viewModel.tagTree
        let expanded = expandedTagIds
        let collapsed = Set(viewModel.allTags.map(\.id).filter { !expanded.contains($0) })
        return tree.rows(collapsed: collapsed)
    }

    private func tagRow(_ row: TagTree.Row) -> some View {
        let tag = row.tag
        let isSelected = viewModel.selectedTagId == tag.id
        let isExpanded = expandedTagIds.contains(tag.id)
        let tint: Color? = isSelected ? .accentColor : nil
        return HStack(spacing: 0) {
            // Pfeil zum Auf-/Zuklappen; bei Tags ohne Kinder nur Platzhalter,
            // damit Symbole und Namen untereinander stehen.
            Group {
                if row.hasChildren {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { setExpanded(tag.id, !isExpanded) }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 28, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? L("navigationMenu.collapseSubTags") : L("navigationMenu.expandSubTags"))
                } else {
                    Color.clear.frame(width: 28, height: 1)
                }
            }
            .padding(.leading, 12 + CGFloat(row.depth) * 20)

            Button {
                Task { await viewModel.selectTag(tag.id) }
                close(then: onNavigate)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: isSelected ? "tag.fill" : "tag")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(tint ?? .primary)
                        .frame(width: 24, alignment: .center)
                    Text(tag.name)
                        .font(.body)
                        .foregroundStyle(tint ?? .primary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.trailing, 20)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            Button {
                tagToMove = tag
            } label: {
                Label(L("navigationMenu.moveTag"), systemImage: "folder")
            }
        }
    }

    private var menuDivider: some View {
        Divider().padding(.leading, 20)
    }

    private func close(then completion: (() -> Void)? = nil) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showSideMenu = false
        }
        if let completion {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                completion()
            }
        }
    }

    @ViewBuilder
    private func filterSection(group: ContentGroup) -> some View {
        ForEach(ArticleFilter.allCases.filter { $0.group == group }) { filter in
            menuRow(
                icon: filter.systemImage,
                label: filterLabel(filter),
                tint: viewModel.selectedFilter == filter && viewModel.selectedTagId == nil
                    ? .accentColor : nil
            ) {
                viewModel.selectedTagId = nil
                viewModel.selectedFilter = filter
                Task { await viewModel.load() }
                close(then: onNavigate)
            }
        }
    }

    private func filterLabel(_ filter: ArticleFilter) -> String {
        // Weiterlesen/-schauen/-hören wird rein client-seitig aus `scrollProgress`
        // gefiltert (siehe ArticlesViewModel.fetchForFilter) – dafür gibt es
        // keine Server-Zählung, daher kein Badge.
        let group = viewModel.counts[filter.group]
        let count: Int
        switch filter.kind {
        case .unread:    count = group.unread
        case .favorites: count = group.favorites
        case .archive:   count = group.archived
        case .continue:  return filter.label
        }
        return String(format: L("navigationMenu.filterWithCount"), filter.label, count)
    }
}

extension View {
    func listFlyout(viewModel: ArticlesViewModel, onNavigate: (() -> Void)? = nil) -> some View {
        modifier(ListFlyoutModifier(viewModel: viewModel, onNavigate: onNavigate))
    }
}
