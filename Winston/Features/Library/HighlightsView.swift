import AppKit
import SwiftData
import SwiftUI

private enum HighlightsPendingAction {
    case select(PersistentIdentifier)
    case switchMode(HighlightsWorkspaceMode)
    case reviewBack
    case dismiss
}

private enum HighlightsExportScope {
    case visible
    case all
}

struct HighlightsView: View {
    let service: HighlightsService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(ToastCenter.self) private var toasts
    @State private var model = HighlightsWorkspaceModel()
    @State private var pendingAction: HighlightsPendingAction?
    @State private var showUnsavedChanges = false
    @State private var isExporting = false

    var body: some View {
        VStack(spacing: 0) {
            HighlightsWorkspaceHeader(
                model: model,
                onSelectMode: requestMode
            )
            Divider()
            HighlightsWorkspaceContent(
                model: model,
                service: service,
                onSelect: requestSelection,
                onToggleFavorite: toggleFavorite,
                onSave: saveDraft,
                onReviewBack: requestReviewBack,
                onReviewAdvance: reviewAdvance
            )
            HighlightsWorkspaceFooter(
                mode: model.mode,
                visibleCount: model.visibleCount,
                totalCount: model.totalCount,
                isExporting: isExporting,
                onExportVisible: { export(.visible) },
                onExportAll: { export(.all) },
                onDone: requestDismiss
            )
        }
        .background { ThemedBackground() }
        .frame(
            minWidth: 820,
            idealWidth: 1_020,
            maxWidth: 1_360,
            minHeight: 640,
            idealHeight: 820,
            maxHeight: .infinity
        )
        .task(id: LibraryMutationLog.shared.catalogRevision) {
            await model.reload(using: service)
            if model.loadError != nil {
                toasts.error(String(localized: "Couldn’t read highlights from the library."))
            }
        }
        .task(id: model.filterRequest) {
            await model.applyFilter(model.filterRequest)
        }
        .confirmationDialog(
            "Save your highlight changes?",
            isPresented: $showUnsavedChanges
        ) {
            Button("Save") {
                if saveDraft() { performPendingAction() }
            }
            .accessibilityIdentifier("highlights.unsaved.save")
            Button("Discard Changes", role: .destructive) {
                model.discardDraft()
                performPendingAction()
            }
            .accessibilityIdentifier("highlights.unsaved.discard")
            Button("Keep Editing", role: .cancel) {
                pendingAction = nil
            }
            .accessibilityIdentifier("highlights.unsaved.keepEditing")
        } message: {
            Text("Your tags or reflection have not been saved.")
        }
        .interactiveDismissDisabled(model.hasUnsavedChanges)
        .onExitCommand(perform: requestDismiss)
    }

    private func requestSelection(_ id: PersistentIdentifier) {
        guard id != model.selectedHighlightID else { return }
        request(.select(id))
    }

    private func requestMode(_ mode: HighlightsWorkspaceMode) {
        guard mode != model.mode else { return }
        request(.switchMode(mode))
    }

    private func requestReviewBack() {
        request(.reviewBack)
    }

    private func requestDismiss() {
        request(.dismiss)
    }

    private func request(_ action: HighlightsPendingAction) {
        if model.hasUnsavedChanges {
            pendingAction = action
            showUnsavedChanges = true
        } else {
            perform(action)
        }
    }

    private func performPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        perform(action)
    }

    private func perform(_ action: HighlightsPendingAction) {
        switch action {
        case .select(let id):
            model.select(id)
        case .switchMode(.library):
            model.enterLibrary()
        case .switchMode(.review):
            model.startReview()
        case .reviewBack:
            model.moveBackInReview()
        case .dismiss:
            dismiss()
        }
    }

    @discardableResult
    private func saveDraft() -> Bool {
        guard let item = model.selectedItem else { return true }
        switch service.updateHighlight(
            id: item.id,
            patch: model.patchForDraft()
        ) {
        case .success(let saved):
            model.acceptSavedItem(saved)
            return true
        case .failure:
            toasts.error(String(localized: "Couldn’t save highlight changes."))
            return false
        }
    }

    private func toggleFavorite(_ item: HighlightWorkspaceItem) {
        switch service.updateHighlight(
            id: item.id,
            patch: HighlightPatch(
                fields: [.favorite],
                favorite: !item.isFavorite
            )
        ) {
        case .success(let saved):
            model.acceptFavoriteUpdate(saved)
        case .failure:
            toasts.error(String(localized: "Couldn’t update the favorite."))
        }
    }

    private func reviewAdvance() {
        guard let item = model.currentReviewItem else { return }
        switch service.updateHighlight(
            id: item.id,
            patch: model.patchForDraft(reviewedAt: .now)
        ) {
        case .success(let saved):
            model.acceptReviewedItem(saved)
        case .failure:
            toasts.error(String(localized: "Couldn’t save this review."))
        }
    }

    private func export(_ scope: HighlightsExportScope) {
        guard !isExporting else { return }
        let items = scope == .visible ? model.visibleItems : model.allItems
        guard !items.isEmpty else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            guard let folder = await FilePanel.chooseFolder(
                message: String(localized: "Choose a folder to export highlights into."),
                prompt: String(localized: "Export")
            ) else { return }
            let snapshots = HighlightsExporter.books(from: items)
            let result = await Task.detached(priority: .userInitiated) {
                HighlightsExporter.export(snapshots, to: folder)
            }.value
            if result.failed == 0 {
                toasts.success(String(localized: "Highlights exported (\(result.written))."))
            } else {
                toasts.error(String(
                    localized: "Exported \(result.written) files; \(result.failed) failed."
                ))
            }
        }
    }
}

private struct HighlightsWorkspaceContent: View {
    let model: HighlightsWorkspaceModel
    let service: HighlightsService
    let onSelect: (PersistentIdentifier) -> Void
    let onToggleFavorite: (HighlightWorkspaceItem) -> Void
    let onSave: () -> Bool
    let onReviewBack: () -> Void
    let onReviewAdvance: () -> Void

    var body: some View {
        ZStack {
            switch model.mode {
            case .library:
                HighlightsLibraryView(
                    model: model,
                    onSelect: onSelect,
                    onToggleFavorite: onToggleFavorite,
                    onSave: onSave,
                    onRetry: { Task { await model.reload(using: service) } }
                )
            case .review:
                HighlightsReviewView(
                    model: model,
                    onToggleFavorite: onToggleFavorite,
                    onBack: onReviewBack,
                    onAdvance: onReviewAdvance,
                    onReviewAgain: model.startReview,
                    onReturnToLibrary: model.enterLibrary
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HighlightsWorkspaceFooter: View {
    let mode: HighlightsWorkspaceMode
    let visibleCount: Int
    let totalCount: Int
    let isExporting: Bool
    let onExportVisible: () -> Void
    let onExportAll: () -> Void
    let onDone: () -> Void

    var body: some View {
        SheetActionBar {
            HStack(spacing: WinstonLayout.space3) {
                if mode == .library {
                    Text(
                        "Showing \(visibleCount) of \(totalCount) highlights",
                        comment: "Highlights footer count: first value is visible, second is total."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Export Current View…", action: onExportVisible)
                        .disabled(visibleCount == 0)
                    Button("Export All…", action: onExportAll)
                        .disabled(totalCount == 0)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
                .accessibilityIdentifier("highlights.export")

                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Exporting highlights")
                }

                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("highlights.done")
            }
        }
    }
}
