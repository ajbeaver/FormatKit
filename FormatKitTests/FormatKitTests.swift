import Foundation
import Testing
@testable import FormatKit

struct FormatKitTests {
    @Test func archiveTypeGatingDetectsKnownArchiveSuffixes() {
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.zip")))
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.tar.gz")))
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.tgz")))
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.tar.xz")))
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.txz")))
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.gz")))
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.xz")))
        #expect(ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.bz2")))
        #expect(!ArchiveSelectionGate.isArchivedURL(URL(fileURLWithPath: "/tmp/a.txt")))

        let urls = [
            URL(fileURLWithPath: "/tmp/keep.txt"),
            URL(fileURLWithPath: "/tmp/already.txz")
        ]
        #expect(ArchiveSelectionGate.containsArchivedItem(urls: urls))
    }

    @Test func outputNamingIsCollisionSafeForSingleAndMultiSelection() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let singleFile = tempRoot.appendingPathComponent("report.txt")
        try Data("x".utf8).write(to: singleFile)

        let singleZip = try ArchiveNameBuilder.outputURL(for: [singleFile], format: .zip, fileManager: fileManager)
        #expect(singleZip.lastPathComponent == "report.txt.zip")
        try Data("occupied".utf8).write(to: singleZip)

        let singleZipCollision = try ArchiveNameBuilder.outputURL(for: [singleFile], format: .zip, fileManager: fileManager)
        #expect(singleZipCollision.lastPathComponent == "report.txt 2.zip")

        let singleTarGz = try ArchiveNameBuilder.outputURL(for: [singleFile], format: .tarGz, fileManager: fileManager)
        #expect(singleTarGz.lastPathComponent == "report.tar.gz")

        let secondFile = tempRoot.appendingPathComponent("notes.md")
        try Data("y".utf8).write(to: secondFile)
        let fixedDate = Date(timeIntervalSince1970: 1_739_941_234)

        let multiZip = try ArchiveNameBuilder.outputURL(for: [singleFile, secondFile], format: .zip, now: fixedDate, fileManager: fileManager)
        #expect(multiZip.deletingPathExtension().lastPathComponent.starts(with: "archive_"))
        #expect(multiZip.lastPathComponent.hasSuffix(".zip"))
        try Data("occupied".utf8).write(to: multiZip)

        let multiZipCollision = try ArchiveNameBuilder.outputURL(for: [singleFile, secondFile], format: .zip, now: fixedDate, fileManager: fileManager)
        #expect(multiZipCollision.lastPathComponent == multiZip.deletingPathExtension().lastPathComponent + " 2.zip")
    }

    @Test func uiFormatNamesMapToTarFormatsAndFlags() {
        #expect(ArchiveFormat.fromPickerDisplayName("ZIP") == .zip)
        #expect(ArchiveFormat.fromPickerDisplayName("GZ") == .tarGz)
        #expect(ArchiveFormat.fromPickerDisplayName("XZ") == .tarXz)
        #expect(ArchiveFormat.fromPickerDisplayName("TAR.GZ") == nil)

        #expect(ArchiveFormat.tarGz.processArguments(outputFileName: "a.tar.gz", relativeItemNames: ["foo"]).prefix(2).elementsEqual(["-czf", "a.tar.gz"]))
        #expect(ArchiveFormat.tarXz.processArguments(outputFileName: "a.tar.xz", relativeItemNames: ["foo"]).prefix(2).elementsEqual(["-cJf", "a.tar.xz"]))
        #expect(ArchiveFormat.zip.processArguments(outputFileName: "a.zip", relativeItemNames: ["foo"]).prefix(3).elementsEqual(["-q", "-r", "a.zip"]))
    }

    @Test func audioDetectionGatingOnlyAcceptsSupportedAudioExtensions() {
        let allAudio = [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.m4a"),
            URL(fileURLWithPath: "/tmp/c.WAV"),
            URL(fileURLWithPath: "/tmp/d.aiff"),
            URL(fileURLWithPath: "/tmp/e.flac")
        ]
        #expect(AudioSelectionGate.allSupportedAudio(urls: allAudio))

        let mixed = [
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.txt")
        ]
        #expect(!AudioSelectionGate.allSupportedAudio(urls: mixed))
        #expect(AudioSelectionGate.inputFormats(for: mixed) == nil)
    }

    @Test func audioConversionMatrixMatchesMvpRules() {
        #expect(AudioConversionMatrix.allowedOutputs(for: .mp3) == [.m4a, .wav, .aiff])
        #expect(AudioConversionMatrix.allowedOutputs(for: .m4a) == [.mp3, .wav, .aiff])
        #expect(AudioConversionMatrix.allowedOutputs(for: .wav) == [.m4a, .mp3, .aiff])
        #expect(AudioConversionMatrix.allowedOutputs(for: .aiff) == [.m4a, .mp3, .wav])
        #expect(AudioConversionMatrix.allowedOutputs(for: .flac) == [.m4a, .mp3, .wav])

        let intersection = AudioConversionMatrix.allowedOutputs(for: [.mp3, .flac])
        #expect(intersection == [.m4a, .wav])
    }

    @Test func convertOutputNamingIsCollisionSafe() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("song.mp3")
        try Data("x".utf8).write(to: source)

        let m4aURL = ConvertNameBuilder.outputURL(for: source, outputFormat: .m4a, fileManager: fileManager)
        #expect(m4aURL.lastPathComponent == "song.m4a")
        try Data("occupied".utf8).write(to: m4aURL)

        let m4aCollision = ConvertNameBuilder.outputURL(for: source, outputFormat: .m4a, fileManager: fileManager)
        #expect(m4aCollision.lastPathComponent == "song 2.m4a")
    }

    @Test func videoOutputOptionsHideSameContainer() {
        let supported: [VideoOutputFormat] = [.mp4, .mov, .m4v]
        #expect(VideoOutputOptionFilter.alternativeOutputs(sourceInput: .mp4, supportedOutputs: supported) == [.mov, .m4v])
        #expect(VideoOutputOptionFilter.alternativeOutputs(sourceInput: .mov, supportedOutputs: supported) == [.mp4, .m4v])
        #expect(VideoOutputOptionFilter.alternativeOutputs(sourceInput: .m4v, supportedOutputs: supported) == [.mp4, .mov])
    }

    @Test func videoOutputOptionsCanBecomeEmptyAfterFiltering() {
        let supported: [VideoOutputFormat] = [.mov]
        #expect(VideoOutputOptionFilter.alternativeOutputs(sourceInput: .mov, supportedOutputs: supported).isEmpty)
    }
}
