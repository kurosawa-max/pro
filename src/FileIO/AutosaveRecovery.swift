import CryptoKit
import Foundation
import simd

struct ProjectAutosaveSnapshot: Equatable, @unchecked Sendable {
    let project: ForgeProject
    let sourceGeneration: MutationGeneration
    let capturedAt: Date
    let sessionID: UUID
    let projectName: String
}

enum ProjectSaveState: Equatable {
    case saved
    case unsavedChanges
    case autosaving
    case autosaved(Date)
    case failed(String)

    var title: String {
        switch self {
        case .saved: "Saved"
        case .unsavedChanges: "Unsaved Changes"
        case .autosaving: "Autosaving…"
        case .autosaved: "Autosaved"
        case .failed: "Autosave Failed"
        }
    }
}

struct RecoveryDescriptor: Equatable, Sendable {
    let capturedAt: Date
    let projectName: String
    let vertexCount: Int
    let triangleCount: Int
    let dimensions: SIMD3<Float>
    let fileSize: Int
    let sessionID: UUID
    let sourceGeneration: MutationGeneration
}

struct InspectedRecovery: Equatable, @unchecked Sendable {
    let descriptor: RecoveryDescriptor
    let project: ForgeProject
}

enum RecoveryStorageError: Error, Equatable, LocalizedError {
    case missing
    case empty
    case oversized
    case unsupportedWrapper
    case invalidLayout
    case checksumMismatch
    case invalidMetadata
    case projectTooLarge
    case insufficientDiskSpace
    case conflictingRecovery
    case arithmeticOverflow

    var errorDescription: String? {
        switch self {
        case .missing: "No recovery snapshot was found."
        case .empty: "The recovery snapshot is empty."
        case .oversized: "The recovery snapshot exceeds the supported size."
        case .unsupportedWrapper: "The recovery snapshot uses an unsupported wrapper version."
        case .invalidLayout: "The recovery snapshot is incomplete or malformed."
        case .checksumMismatch: "The recovery snapshot failed its integrity check."
        case .invalidMetadata: "The recovery snapshot metadata does not match its project."
        case .projectTooLarge: "The encoded project exceeds the recovery project limit."
        case .insufficientDiskSpace: "There is not enough free storage for a safe recovery write."
        case .conflictingRecovery: "Recovery already contains unsaved work from another project."
        case .arithmeticOverflow: "The recovery size calculation overflowed."
        }
    }
}

private struct RecoveryMetadata: Codable, Equatable {
    static let schemaIdentifier = "com.forge3d.recovery"
    static let wrapperVersion = 1

    let schema: String
    let version: Int
    let projectFormatVersion: Int
    let capturedAt: Date
    let projectName: String
    let vertexCount: Int
    let triangleCount: Int
    let dimensions: [Float]
    let sessionID: UUID
    let sourceGenerationValue: UInt64
    let sourceGenerationIdentity: UUID
}

enum ProjectRecoveryCodec {
    static let maximumProjectBytes = 128 * 1_024 * 1_024
    static let maximumRecoveryBytes = 160 * 1_024 * 1_024
    private static let magic = Data("F3DREC01".utf8)
    private static let headerByteCount = 56
    private static let checksumByteCount = 32

    static func encode(_ snapshot: ProjectAutosaveSnapshot) throws -> Data {
        let projectData = try ProjectCodec.encode(snapshot.project)
        guard !projectData.isEmpty else { throw RecoveryStorageError.empty }
        try validateProjectByteCount(projectData.count)
        let dimensions = ObjectDimensions.make(mesh: snapshot.project.mesh, transform: snapshot.project.transform)?.worldSize ?? .zero
        guard dimensions.allFinite else { throw RecoveryStorageError.invalidMetadata }
        let metadata = RecoveryMetadata(
            schema: RecoveryMetadata.schemaIdentifier,
            version: RecoveryMetadata.wrapperVersion,
            projectFormatVersion: snapshot.project.formatVersion,
            capturedAt: snapshot.capturedAt,
            projectName: String(snapshot.projectName.prefix(128)),
            vertexCount: snapshot.project.mesh.vertices.count,
            triangleCount: snapshot.project.mesh.indices.count / 3,
            dimensions: [dimensions.x, dimensions.y, dimensions.z],
            sessionID: snapshot.sessionID,
            sourceGenerationValue: snapshot.sourceGeneration.value,
            sourceGenerationIdentity: snapshot.sourceGeneration.overflowIdentity
        )
        let metadataEncoder = JSONEncoder()
        metadataEncoder.outputFormatting = [.sortedKeys]
        let metadataData = try metadataEncoder.encode(metadata)
        guard metadataData.count <= Int(UInt32.max) else { throw RecoveryStorageError.arithmeticOverflow }
        let (payloadBytes, payloadOverflow) = metadataData.count.addingReportingOverflow(projectData.count)
        let (totalBytes, totalOverflow) = headerByteCount.addingReportingOverflow(payloadBytes)
        guard !payloadOverflow, !totalOverflow, totalBytes <= maximumRecoveryBytes else {
            throw payloadOverflow || totalOverflow ? RecoveryStorageError.arithmeticOverflow : RecoveryStorageError.oversized
        }

        var result = Data()
        result.reserveCapacity(totalBytes)
        result.append(magic)
        result.appendLittleEndian(UInt32(RecoveryMetadata.wrapperVersion))
        result.appendLittleEndian(UInt32(metadataData.count))
        result.appendLittleEndian(UInt64(projectData.count))
        var checksum = SHA256()
        checksum.update(data: metadataData)
        checksum.update(data: projectData)
        result.append(Data(checksum.finalize()))
        result.append(metadataData)
        result.append(projectData)
        return result
    }

    static func decode(_ data: Data) throws -> InspectedRecovery {
        guard !data.isEmpty else { throw RecoveryStorageError.empty }
        try validateRecoveryByteCount(data.count)
        guard data.count >= headerByteCount, data.prefix(magic.count) == magic else {
            throw RecoveryStorageError.invalidLayout
        }
        guard let version = data.littleEndianUInt32(at: 8),
              version == UInt32(RecoveryMetadata.wrapperVersion) else {
            throw RecoveryStorageError.unsupportedWrapper
        }
        guard let metadataLengthValue = data.littleEndianUInt32(at: 12),
              let projectLengthValue = data.littleEndianUInt64(at: 16),
              projectLengthValue <= UInt64(Int.max) else {
            throw RecoveryStorageError.invalidLayout
        }
        let metadataLength = Int(metadataLengthValue)
        let projectLength = Int(projectLengthValue)
        guard projectLength > 0, projectLength <= maximumProjectBytes else {
            throw projectLength == 0 ? RecoveryStorageError.empty : RecoveryStorageError.projectTooLarge
        }
        let (metadataEnd, metadataOverflow) = headerByteCount.addingReportingOverflow(metadataLength)
        let (expectedEnd, projectOverflow) = metadataEnd.addingReportingOverflow(projectLength)
        guard !metadataOverflow, !projectOverflow, expectedEnd == data.count else {
            throw metadataOverflow || projectOverflow ? RecoveryStorageError.arithmeticOverflow : RecoveryStorageError.invalidLayout
        }
        let expectedChecksum = Data(data[24..<(24 + checksumByteCount)])
        let metadataData = Data(data[headerByteCount..<metadataEnd])
        let projectData = Data(data[metadataEnd..<expectedEnd])
        var checksum = SHA256()
        checksum.update(data: metadataData)
        checksum.update(data: projectData)
        guard Data(checksum.finalize()) == expectedChecksum else {
            throw RecoveryStorageError.checksumMismatch
        }
        let metadata = try JSONDecoder().decode(RecoveryMetadata.self, from: metadataData)
        guard metadata.schema == RecoveryMetadata.schemaIdentifier,
              metadata.version == RecoveryMetadata.wrapperVersion,
              metadata.projectFormatVersion == ForgeProject.currentFormatVersion,
              metadata.dimensions.count == 3,
              metadata.dimensions.allSatisfy(\.isFinite) else {
            throw RecoveryStorageError.invalidMetadata
        }
        let project = try ProjectCodec.decode(projectData, maximumBytes: maximumProjectBytes)
        guard project.formatVersion == metadata.projectFormatVersion,
              project.mesh.vertices.count == metadata.vertexCount,
              project.mesh.indices.count / 3 == metadata.triangleCount else {
            throw RecoveryStorageError.invalidMetadata
        }
        let actualDimensions = ObjectDimensions.make(mesh: project.mesh, transform: project.transform)?.worldSize ?? .zero
        let storedDimensions = SIMD3<Float>(metadata.dimensions[0], metadata.dimensions[1], metadata.dimensions[2])
        guard actualDimensions.allFinite, storedDimensions.allFinite,
              simd_length(actualDimensions - storedDimensions) <= 0.000_1 else {
            throw RecoveryStorageError.invalidMetadata
        }
        let descriptor = RecoveryDescriptor(
            capturedAt: metadata.capturedAt,
            projectName: metadata.projectName.isEmpty ? "Unsaved Project" : metadata.projectName,
            vertexCount: metadata.vertexCount,
            triangleCount: metadata.triangleCount,
            dimensions: storedDimensions,
            fileSize: data.count,
            sessionID: metadata.sessionID,
            sourceGeneration: MutationGeneration(value: metadata.sourceGenerationValue,
                                                 overflowIdentity: metadata.sourceGenerationIdentity)
        )
        return InspectedRecovery(descriptor: descriptor, project: project)
    }

    static func validateProjectByteCount(_ count: Int) throws {
        guard count >= 0 else { throw RecoveryStorageError.arithmeticOverflow }
        guard count <= maximumProjectBytes else { throw RecoveryStorageError.projectTooLarge }
    }

    static func validateRecoveryByteCount(_ count: Int) throws {
        guard count >= 0 else { throw RecoveryStorageError.arithmeticOverflow }
        guard count <= maximumRecoveryBytes else { throw RecoveryStorageError.oversized }
    }
}

struct ProjectRecoveryStorage: @unchecked Sendable {
    let directoryURL: URL
    let fileManager: FileManager
    let beforeReplacement: (@Sendable () throws -> Void)?

    init(directoryURL: URL, fileManager: FileManager = .default,
         beforeReplacement: (@Sendable () throws -> Void)? = nil) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.beforeReplacement = beforeReplacement
    }

    static func applicationSupport(fileManager: FileManager = .default) -> ProjectRecoveryStorage {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return ProjectRecoveryStorage(directoryURL: root.appendingPathComponent("Forge3D/Recovery", isDirectory: true),
                                      fileManager: fileManager)
    }

    var recoveryURL: URL { directoryURL.appendingPathComponent("current.recovery", isDirectory: false) }

    func write(_ snapshot: ProjectAutosaveSnapshot) throws -> RecoveryDescriptor {
        let data = try ProjectRecoveryCodec.encode(snapshot)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let available = try? directoryURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           available < Int64(data.count + 1_024 * 1_024) {
            throw RecoveryStorageError.insufficientDiskSpace
        }
        if fileManager.fileExists(atPath: recoveryURL.path) {
            let existing = try inspect()
            guard existing.descriptor.sessionID == snapshot.sessionID else {
                throw RecoveryStorageError.conflictingRecovery
            }
        }

        let temporaryURL = directoryURL.appendingPathComponent("current.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.synchronize()
        try handle.close()
        let verifiedData = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
        _ = try ProjectRecoveryCodec.decode(verifiedData)
        try beforeReplacement?()
        if fileManager.fileExists(atPath: recoveryURL.path) {
            _ = try fileManager.replaceItemAt(recoveryURL, withItemAt: temporaryURL,
                                              backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporaryURL, to: recoveryURL)
        }
        return try inspect().descriptor
    }

    func inspect() throws -> InspectedRecovery {
        guard fileManager.fileExists(atPath: recoveryURL.path) else { throw RecoveryStorageError.missing }
        if let fileSize = try recoveryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            guard fileSize > 0 else { throw RecoveryStorageError.empty }
            try ProjectRecoveryCodec.validateRecoveryByteCount(fileSize)
        }
        let data = try Data(contentsOf: recoveryURL, options: .mappedIfSafe)
        return try ProjectRecoveryCodec.decode(data)
    }

    func discard() throws {
        guard fileManager.fileExists(atPath: recoveryURL.path) else { return }
        try fileManager.removeItem(at: recoveryURL)
    }

    func discardSavedRecovery(sessionID: UUID, generation: MutationGeneration) throws {
        guard fileManager.fileExists(atPath: recoveryURL.path) else { return }
        let recovery = try inspect()
        guard recovery.descriptor.sessionID == sessionID,
              recovery.descriptor.sourceGeneration.isNotNewer(than: generation) else { return }
        try fileManager.removeItem(at: recoveryURL)
    }
}

protocol AutosaveDelayScheduler: Sendable {
    func wait(nanoseconds: UInt64) async throws
}

struct ContinuousAutosaveDelayScheduler: AutosaveDelayScheduler {
    func wait(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

enum AutosaveScheduleResult: @unchecked Sendable {
    case started(ProjectAutosaveSnapshot)
    case success(ProjectAutosaveSnapshot, RecoveryDescriptor)
    case failure(ProjectAutosaveSnapshot, String)
}

actor ProjectAutosaveCoordinator {
    static let defaultDebounceNanoseconds: UInt64 = 2_000_000_000

    private let storage: ProjectRecoveryStorage
    private let scheduler: any AutosaveDelayScheduler
    private let debounceNanoseconds: UInt64
    private var pendingTask: Task<Void, Never>?
    private var requestGeneration = MutationGeneration()
    private(set) var successfulWriteCount = 0

    init(storage: ProjectRecoveryStorage = .applicationSupport(),
         scheduler: any AutosaveDelayScheduler = ContinuousAutosaveDelayScheduler(),
         debounceNanoseconds: UInt64 = defaultDebounceNanoseconds) {
        self.storage = storage
        self.scheduler = scheduler
        self.debounceNanoseconds = debounceNanoseconds
    }

    func schedule(_ snapshot: ProjectAutosaveSnapshot,
                  completion: @escaping @Sendable (AutosaveScheduleResult) -> Void) {
        pendingTask?.cancel()
        requestGeneration.advance()
        let request = requestGeneration
        pendingTask = Task { [weak self] in
            await self?.runScheduled(snapshot, request: request, completion: completion)
        }
    }

    private func runScheduled(_ snapshot: ProjectAutosaveSnapshot, request: MutationGeneration,
                              completion: @escaping @Sendable (AutosaveScheduleResult) -> Void) async {
        do {
            try await scheduler.wait(nanoseconds: debounceNanoseconds)
            try Task.checkCancellation()
            guard request == requestGeneration else { throw CancellationError() }
            completion(.started(snapshot))
            let descriptor = try storage.write(snapshot)
            try Task.checkCancellation()
            guard request == requestGeneration else { throw CancellationError() }
            successfulWriteCount += 1
            pendingTask = nil
            completion(.success(snapshot, descriptor))
        } catch is CancellationError {
            return
        } catch {
            if request == requestGeneration { pendingTask = nil }
            completion(.failure(snapshot, error.localizedDescription))
        }
    }

    func flush(_ snapshot: ProjectAutosaveSnapshot) throws -> RecoveryDescriptor {
        pendingTask?.cancel()
        pendingTask = nil
        requestGeneration.advance()
        let descriptor = try storage.write(snapshot)
        successfulWriteCount += 1
        return descriptor
    }

    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        requestGeneration.advance()
    }

    func inspectRecovery() throws -> InspectedRecovery { try storage.inspect() }
    func discardRecovery() throws { try storage.discard() }
    func discardSavedRecovery(sessionID: UUID, generation: MutationGeneration) throws {
        try storage.discardSavedRecovery(sessionID: sessionID, generation: generation)
    }
    var hasPendingAutosave: Bool { pendingTask != nil }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func littleEndianUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(self[offset + index]) << UInt64(index * 8) }
        return value
    }
}
