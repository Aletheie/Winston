import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WorkDetailSheet: View {
    let work: Work
    let viewModel: LibraryViewModel
    let onShowInLibrary: (Book) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage("workDetailCompactList") private var compactList = false
    @State private var title = ""
    @State private var author = ""
    @State private var selectedEditionUUIDs: Set<UUID> = []
    @State private var isAddingEdition = false
    @State private var showCompare = false
    @State private var showMerge = false
    @State private var deleteTarget: Book?
    @State private var isConfirmingDelete = false
    @State private var isConfirmingEditionMerge = false

    private static let ebookTypes: [UTType] = libraryEbookExtensions
        .compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        if work.modelContext == nil {
            Color.clear.onAppear { dismiss() }
        } else {
            let editions = sortedEditions
            let comparedEditions = editions.filter { selectedEditionUUIDs.contains($0.uuid) }

            VStack(spacing: 0) {
                WorkDetailHeader(
                    title: $title,
                    author: $author,
                    editionCount: editions.count,
                    compactList: $compactList,
                    onCommit: commitIdentity,
                    onClose: { dismiss() }
                )
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        WorkEditionSection(
                            editions: editions,
                            work: work,
                            preferredEditionUUID: WorkService.preferredEdition(in: work)?.uuid,
                            compactList: compactList,
                            selectedEditionUUIDs: $selectedEditionUUIDs,
                            service: viewModel.editions,
                            onShowInLibrary: onShowInLibrary,
                            onDelete: requestDelete
                        )
                        if editions.count == 1 {
                            Button {
                                isAddingEdition = true
                            } label: {
                                Label("Add another translation or edition", systemImage: "plus.circle")
                            }
                            .buttonStyle(.link)
                            .font(theme.label(size: 10))
                        }
                    }
                    .padding(18)
                }
                Divider()
                WorkDetailFooter(
                    canUseComparison: comparedEditions.count == 2,
                    showMerge: $showMerge,
                    isConfirmingEditionMerge: $isConfirmingEditionMerge,
                    showCompare: $showCompare,
                    isAddingEdition: $isAddingEdition
                )
            }
            .frame(minWidth: 560, idealWidth: 680, maxWidth: 980, minHeight: 540, idealHeight: 700)
            .onAppear {
                title = work.title ?? ""
                author = work.author ?? ""
            }
            .fileImporter(
                isPresented: $isAddingEdition,
                allowedContentTypes: Self.ebookTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    viewModel.addEditions(from: urls, to: work)
                }
            }
            .sheet(isPresented: $showCompare) {
                if comparedEditions.count == 2 {
                    EditionCompareView(left: comparedEditions[0], right: comparedEditions[1])
                }
            }
            .sheet(isPresented: $showMerge) {
                WorkMergePicker(work: work, service: viewModel.editions)
            }
            .confirmationDialog(
                "Delete edition and files?",
                isPresented: $isConfirmingDelete,
                presenting: deleteTarget
            ) { book in
                Button("Delete Edition and Files", role: .destructive) {
                    viewModel.remove(book)
                }
            } message: { _ in
                Text("All files belonging to this edition are deleted. Other editions stay intact.")
            }
            .confirmationDialog(
                "Merge these editions?",
                isPresented: $isConfirmingEditionMerge,
                presenting: viewModel.editions.mergeSurvivor(among: comparedEditions)
            ) { _ in
                Button("Merge Editions", role: .destructive) {
                    _ = viewModel.editions.mergeEditions(comparedEditions)
                    selectedEditionUUIDs.removeAll()
                }
            } message: { survivor in
                Text("Both editions become one. All files are kept as files of “\(survivor.displayTitle)”.")
            }
        }
    }

    private var sortedEditions: [Book] {
        work.editions.sorted {
            if $0.dateAdded != $1.dateAdded { return $0.dateAdded < $1.dateAdded }
            return $0.uuid.uuidString < $1.uuid.uuidString
        }
    }

    private func requestDelete(_ book: Book) {
        deleteTarget = book
        isConfirmingDelete = true
    }

    private func commitIdentity() {
        viewModel.editions.updateWork(work, title: title, author: author)
    }
}

private struct WorkDetailHeader: View {
    @Binding var title: String
    @Binding var author: String
    let editionCount: Int
    @Binding var compactList: Bool
    let onCommit: () -> Void
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @FocusState private var focusedField: Field?

    private enum Field {
        case title
        case author
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 24))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Work Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(theme.body(size: 17, weight: .bold))
                    .focused($focusedField, equals: .title)
                    .onSubmit(onCommit)
                TextField("Author", text: $author)
                    .textFieldStyle(.plain)
                    .font(theme.label(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .focused($focusedField, equals: .author)
                    .onSubmit(onCommit)
                theme.styledText(
                    terminal: "vydani: \(editionCount)",
                    native: "You own \(editionCount) editions"
                )
                .font(theme.label(size: 10))
                .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            Picker("Layout", selection: $compactList) {
                Image(systemName: "square.grid.2x2")
                    .tag(false)
                    .accessibilityLabel("Card grid")
                Image(systemName: "list.bullet")
                    .tag(true)
                    .accessibilityLabel("Compact list")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 78)
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue != nil, newValue == nil { onCommit() }
        }
    }
}

private struct WorkEditionSection: View {
    let editions: [Book]
    let work: Work
    let preferredEditionUUID: UUID?
    let compactList: Bool
    @Binding var selectedEditionUUIDs: Set<UUID>
    let service: EditionService
    let onShowInLibrary: (Book) -> Void
    let onDelete: (Book) -> Void

    var body: some View {
        if compactList {
            LazyVStack(spacing: 8) {
                ForEach(editions) { edition in
                    WorkEditionCard(
                        book: edition,
                        work: work,
                        isPreferred: preferredEditionUUID == edition.uuid,
                        compact: true,
                        selectedEditionUUIDs: $selectedEditionUUIDs,
                        service: service,
                        onShowInLibrary: onShowInLibrary,
                        onDelete: onDelete
                    )
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(editions) { edition in
                    WorkEditionCard(
                        book: edition,
                        work: work,
                        isPreferred: preferredEditionUUID == edition.uuid,
                        compact: false,
                        selectedEditionUUIDs: $selectedEditionUUIDs,
                        service: service,
                        onShowInLibrary: onShowInLibrary,
                        onDelete: onDelete
                    )
                }
            }
        }
    }
}

private struct WorkDetailFooter: View {
    let canUseComparison: Bool
    @Binding var showMerge: Bool
    @Binding var isConfirmingEditionMerge: Bool
    @Binding var showCompare: Bool
    @Binding var isAddingEdition: Bool

    var body: some View {
        HStack {
            Button("Merge With Another Work…") { showMerge = true }
            Spacer()
            Button("Merge Editions") { isConfirmingEditionMerge = true }
                .disabled(!canUseComparison)
            Button("Compare") { showCompare = true }
                .disabled(!canUseComparison)
            Button("Add Edition…") { isAddingEdition = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
    }
}
