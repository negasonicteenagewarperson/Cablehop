import SwiftUI

/// Icon/thumbnail view of a folder, best for photos.
struct FileGridView: View {
    let files: [RemoteFile]
    let serial: String
    @Binding var selection: Set<RemoteFile.ID>
    let open: (RemoteFile) -> Void
    let dropIntoFolder: (RemoteFile, [URL]) -> Void
    let menu: (Set<RemoteFile.ID>) -> [MenuSpec]

    @AppStorage("gridSize") private var cellSize = 120.0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.4), spacing: 8)], spacing: 12) {
                    ForEach(files) { file in
                        GridCell(file: file, serial: serial, size: cellSize, isSelected: selection.contains(file.id))
                            // Clicks, right-clicks and drags go through AppKit so items drag into Finder as real files.
                            .overlay {
                                GridItemInteraction(
                                    file: file,
                                    onSelect: { select(file, modifiers: $0) },
                                    onClickUp: { selection = [file.id] },
                                    onOpen: { open(file) },
                                    menu: { MenuSpec.menu(menu(menuSelection(for: file))) },
                                    dragFiles: { dragFiles(startingWith: file) },
                                    serial: serial)
                            }
                            .dropDestination(for: URL.self) { urls, _ in
                                guard file.isDirectory else { return false }
                                dropIntoFolder(file, urls.filter(\.isFileURL))
                                return true
                            }
                    }
                }
                .padding(14)
            }
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .onTapGesture { selection.removeAll() }
            .contextMenu { MenuSpecView(specs: menu([])) }

            HStack {
                Spacer()
                Image(systemName: "photo").font(.caption2)
                Slider(value: $cellSize, in: 80...240).frame(width: 120).controlSize(.mini)
                    .help("Thumbnail size")
                Image(systemName: "photo").font(.callout)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        }
    }

    /// Right-clicking an item inside the selection acts on the whole selection, like Finder.
    private func menuSelection(for file: RemoteFile) -> Set<RemoteFile.ID> {
        if !selection.contains(file.id) { selection = [file.id] }
        return selection
    }

    private func dragFiles(startingWith file: RemoteFile) -> [RemoteFile] {
        if !selection.contains(file.id) { selection = [file.id] }
        return files.filter { selection.contains($0.id) }
    }

    private func select(_ file: RemoteFile, modifiers flags: NSEvent.ModifierFlags) {
        if flags.contains(.command) {
            if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
        } else if flags.contains(.shift), let anchor = files.firstIndex(where: { selection.contains($0.id) }),
                  let target = files.firstIndex(of: file) {
            selection = Set(files[min(anchor, target)...max(anchor, target)].map(\.id))
        } else if !selection.contains(file.id) || selection.count == 1 {
            selection = [file.id]
        }
    }
}

private struct GridCell: View {
    let file: RemoteFile
    let serial: String
    let size: Double
    let isSelected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size - 12, height: size - 12)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(nsImage: IconCache.icon(for: file))
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.62, height: size * 0.62)
                }
                if file.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: size * 0.22))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .frame(width: size - 12, height: size - 12)
            .padding(4)
            .background(isSelected ? Color.secondary.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))

            Text(file.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .foregroundStyle(isSelected ? .white : .primary)
                .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                .opacity(file.isHidden ? 0.6 : 1)
        }
        .frame(width: size)
        .contentShape(Rectangle())
        .help(file.path)
        .task(id: file.id) {
            guard file.isImage || (file.isVideo && Phones.isMTP(serial)) else { return }
            thumbnail = await ThumbnailLoader.shared.thumbnail(for: file, serial: serial)
        }
    }
}
