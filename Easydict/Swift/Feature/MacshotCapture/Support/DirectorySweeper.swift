//
//  DirectorySweeper.swift
//  Easydict
//
//  Extracted from macshot's LaunchCleanup for ClipboardBackingStore.
//

import Foundation

// MARK: - DirectorySweeper

//
// One place that knows how to walk a directory, read modification times,
// and delete files older than a TTL that pass a caller-supplied filter.
// Every cleanup we do at launch boils down to this operation — sharing
// the implementation keeps each cleaner down to declarative config.

enum DirectorySweeper {
    /// Result of a sweep, handy for logging.
    struct Result {
        var removed: Int = 0
        var bytesFreed: UInt64 = 0
    }

    /// Walk `directory` (no recursion), and delete regular files that
    /// satisfy `shouldDelete`. When `olderThan` is non-nil, files
    /// modified more recently than `now - olderThan` are skipped so
    /// in-flight writes can't get clobbered. Returns counts for logging.
    ///
    /// - Parameters:
    ///   - directory: Directory to scan. Missing directory → empty result.
    ///   - olderThan: Age gate. Pass nil to skip the age check entirely
    ///     (e.g. when using an independent signal like "orphaned from
    ///     an index file").
    ///   - shouldDelete: Filter run on the filename (last path component
    ///     only). Return true to include the file, false to leave it.
    @discardableResult
    static func sweep(
        directory: URL,
        olderThan ttl: TimeInterval?,
        shouldDelete: (String) -> Bool
    )
        -> Result {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return Result() }

        let cutoff: Date? = ttl.map { Date().addingTimeInterval(-$0) }
        var result = Result()

        for url in contents {
            guard shouldDelete(url.lastPathComponent) else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .fileSizeKey,
            ]) else { continue }
            guard values.isRegularFile == true else { continue }
            if let cutoff = cutoff {
                guard let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
            }

            let size = UInt64(values.fileSize ?? 0)
            if (try? fm.removeItem(at: url)) != nil {
                result.removed += 1
                result.bytesFreed += size
            }
        }
        return result
    }
}
