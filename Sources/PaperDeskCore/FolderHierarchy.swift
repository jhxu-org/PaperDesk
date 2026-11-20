import Foundation

public struct FolderEntry: Identifiable, Sendable {
    public let folder: LibraryFolder
    public let depth: Int
    public let path: String
    public var id: String { folder.id }
}

/// One hierarchy implementation for navigation, validation, and cloud restore ordering.
public struct FolderHierarchy: Sendable {
    public let folders: [LibraryFolder]
    private let byID: [String: LibraryFolder]
    private let children: [String?: [LibraryFolder]]

    public init(_ folders: [LibraryFolder]) {
        self.folders = folders
        byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        children = Dictionary(grouping: folders, by: \.parentID)
    }

    public var entries: [FolderEntry] {
        var stack = (children[nil] ?? []).reversed().map { ($0, 0, $0.name) }
        var result: [FolderEntry] = [], visited = Set<String>()
        while let (folder, depth, path) = stack.popLast() {
            guard visited.insert(folder.id).inserted else { continue }
            result.append(FolderEntry(folder: folder, depth: depth, path: path))
            for child in (children[folder.id] ?? []).reversed() { stack.append((child, depth + 1, path + " / " + child.name)) }
        }
        return result
    }

    public func hasChildren(_ id: String) -> Bool { !(children[id] ?? []).isEmpty }

    public func ancestorIDs(of id: String) -> [String] {
        var result: [String] = [], visited: Set<String> = [id]
        var parent = byID[id]?.parentID
        while let current = parent, visited.insert(current).inserted, let folder = byID[current] {
            result.append(current); parent = folder.parentID
        }
        return result
    }

    public func descendantIDs(of id: String) -> Set<String> {
        guard byID[id] != nil else { return [] }
        var result = Set<String>(), pending = [id]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending.append(contentsOf: (children[current] ?? []).map(\.id))
        }
        return result
    }

    public func path(for id: String) -> String? {
        guard let folder = byID[id] else { return nil }
        return (ancestorIDs(of: id).reversed().compactMap { byID[$0]?.name } + [folder.name]).joined(separator: " / ")
    }

    public static func namesEqual(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    public func validate() throws {
        guard byID.count == folders.count else { throw PaperDeskError.message("文件夹编号重复。") }
        for folder in folders {
            guard !folder.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, folder.name.count <= 80,
                  !folder.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw PaperDeskError.message("文件夹名称需为 1–80 个字符，且不能包含换行或控制字符。")
            }
            var visited: Set<String> = [folder.id], parent = folder.parentID
            while let id = parent {
                guard let ancestor = byID[id] else { throw PaperDeskError.message("上级文件夹已不存在。") }
                guard visited.insert(id).inserted else { throw PaperDeskError.message("不能把文件夹放入自身或自己的子文件夹。") }
                parent = ancestor.parentID
            }
        }
        for siblings in children.values {
            for (index, folder) in siblings.enumerated() {
                guard !siblings.prefix(index).contains(where: { Self.namesEqual($0.name, folder.name) }) else {
                    throw PaperDeskError.message("同一目录下已有同名文件夹，请换一个名称。")
                }
            }
        }
    }
}
