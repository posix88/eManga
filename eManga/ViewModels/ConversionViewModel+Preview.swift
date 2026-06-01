#if DEBUG
import Foundation

extension ConversionViewModel {
    static func mock(
        withJobs: Bool = true,
        outputURL: URL? = URL(fileURLWithPath: "/Users/demo/Desktop/Output")
    ) -> ConversionViewModel {
        let vm = ConversionViewModel()
        vm.outputURL = outputURL

        guard withJobs else { return vm }

        let pending = ConversionJob(
            pdfURL: URL(fileURLWithPath: "/Users/demo/Documents/One Piece Vol 1.pdf")
        )

        let processing = ConversionJob(
            pdfURL: URL(fileURLWithPath: "/Users/demo/Documents/Naruto Vol 3.pdf")
        )
        processing.status = .processing(progress: 0.6, message: "Converting page 45 of 75…")

        let done = ConversionJob(
            pdfURL: URL(fileURLWithPath: "/Users/demo/Documents/Bleach Vol 7.pdf")
        )
        done.status = .done

        let failed = ConversionJob(
            pdfURL: URL(fileURLWithPath: "/Users/demo/Documents/Berserk Vol 12.pdf")
        )
        failed.status = .failed(
            NSError(domain: "Preview", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "File could not be opened"])
        )

        vm.jobs = [pending, processing, done, failed]
        return vm
    }
}
#endif
