import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ConversionViewModel {
    var jobs: [ConversionJob]       = []
    var settings                    = ConversionSettings()
    var outputURL: URL?             = nil
    var isConverting: Bool          = false

    // MARK: - File management

    func addPDFs(_ urls: [URL]) {
        let candidates = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let deduplicated = candidates.filter { url in !jobs.contains(where: { $0.pdfURL == url }) }

        let duplicateCount = candidates.count - deduplicated.count
        if duplicateCount > 0 {
            Logger.viewModel.notice("Skipped \(duplicateCount, privacy: .public) duplicate PDF(s)")
        }

        let newJobs = deduplicated.map { ConversionJob(pdfURL: $0) }
        jobs.append(contentsOf: newJobs)

        Logger.viewModel.info(
            "Added \(newJobs.count, privacy: .public) PDF(s); queue size: \(self.jobs.count, privacy: .public)"
        )
    }

    func removeJob(_ job: ConversionJob) {
        Logger.viewModel.info(
            "Removing job \(job.id, privacy: .public) — \(job.filename, privacy: .private(mask: .hash))"
        )
        jobs.removeAll { $0.id == job.id }
    }

    func clearCompleted() {
        let count = jobs.filter(\.isComplete).count
        jobs.removeAll { $0.isComplete }
        Logger.viewModel.info("Cleared \(count, privacy: .public) completed job(s); remaining: \(self.jobs.count, privacy: .public)")
    }

    // MARK: - Output folder

    private static let outputBookmarkKey = "outputFolderBookmark"

    func setOutputFolder(_ url: URL) {
        // Persist as a security-scoped bookmark so access survives app restarts
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.outputBookmarkKey)
            Logger.viewModel.debug("Security-scoped bookmark saved for output folder")
        } else {
            Logger.viewModel.warning("Could not create security-scoped bookmark — access will not persist across relaunches")
        }
        outputURL = url
        Logger.viewModel.info("Output folder set: \(url.path(percentEncoded: false), privacy: .private(mask: .hash))")
    }

    func restoreOutputFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.outputBookmarkKey) else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            Logger.viewModel.warning("Failed to resolve output folder bookmark — clearing saved value")
            UserDefaults.standard.removeObject(forKey: Self.outputBookmarkKey)
            return
        }
        if stale {
            Logger.viewModel.warning("Output folder bookmark is stale — refreshing")
            if let refreshed = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(refreshed, forKey: Self.outputBookmarkKey)
            }
        }
        outputURL = url
        Logger.viewModel.info("Output folder restored from bookmark: \(url.path(percentEncoded: false), privacy: .private(mask: .hash))")
    }

    // MARK: - Conversion

    func startConversion() {
        guard !isConverting, let outputURL else {
            Logger.viewModel.notice(
                "startConversion ignored — isConverting: \(self.isConverting, privacy: .public), outputURL set: \(self.outputURL != nil, privacy: .public)"
            )
            return
        }
        isConverting = true

        var pending = jobs.filter {
            if case .pending = $0.status { return true }
            return false
        }

        Logger.viewModel.notice("Conversion started — \(pending.count, privacy: .public) pending job(s)")

        Task {
            let clock = ContinuousClock()
            let start = clock.now

            // Run up to 2 conversions concurrently — each already uses all CPU cores internally,
            // so 2 parallel jobs keeps cores busy between render and archive phases.
            let maxConcurrent = min(2, pending.count)
            await withTaskGroup(of: Void.self) { group in
                // Seed the initial batch
                for _ in 0 ..< maxConcurrent {
                    let job = pending.removeFirst()
                    group.addTask { await self.convertJob(job, outputURL: outputURL) }
                }
                // As each job finishes, pull the next one from the queue
                while await group.next() != nil {
                    guard !pending.isEmpty else { continue }
                    let job = pending.removeFirst()
                    group.addTask { await self.convertJob(job, outputURL: outputURL) }
                }
            }

            let elapsed = clock.now - start
            Logger.viewModel.notice(
                "All conversions finished in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)"
            )
            isConverting = false
        }
    }

    private func convertJob(_ job: ConversionJob, outputURL: URL) async {
        // Activate sandbox access for the user-selected folder for the duration of this conversion
        let accessed = outputURL.startAccessingSecurityScopedResource()
        defer { if accessed { outputURL.stopAccessingSecurityScopedResource() } }

        guard let startIdx = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[startIdx].status = .processing(progress: 0, message: String(localized: "Starting…"))

        Logger.viewModel.info(
            "Starting job \(job.id, privacy: .public) — \(job.filename, privacy: .private(mask: .hash))"
        )
        let clock = ContinuousClock()
        let start = clock.now

        do {
            for try await event in PDFConverter.convert(pdf: job.pdfURL, outputDir: outputURL, settings: settings) {
                guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { break }
                switch event {
                case let .progress(fraction, message):
                    jobs[i].status = .processing(progress: fraction, message: message)
                case .completed:
                    jobs[i].status = .done
                    Logger.viewModel.notice(
                        "Job \(job.id, privacy: .public) done in \((clock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)"
                    )
                }
            }
        } catch {
            let elapsed = clock.now - start
            guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
            jobs[i].status = .failed(error)
            Logger.viewModel.error(
                "Job \(job.id, privacy: .public) failed after \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
