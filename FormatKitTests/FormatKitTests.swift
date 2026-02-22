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
        #expect(ArchiveFormat.zip.processArguments(outputFileName: "a.zip", relativeItemNames: ["foo"]).prefix(2).elementsEqual(["-r", "a.zip"]))
    }
}
