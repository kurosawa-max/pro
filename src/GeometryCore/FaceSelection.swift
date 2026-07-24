import Foundation

enum WorkspaceInteractionMode: String, CaseIterable, Hashable {
    case sculpt = "Sculpt"
    case faceSelect = "Face Select"
    case edgeSelect = "Edge Select"
}

enum FaceSelectionOperation: String, CaseIterable, Hashable {
    case replace = "Replace"
    case add = "Add"
    case remove = "Remove"
    case toggle = "Toggle"
}

struct FaceSelectionVersion: Equatable {
    let identity: UUID
    let value: UInt64
}

struct FaceSelection: Equatable {
    static let maximumTriangleCount = 4_000_000

    let sourceTopologyID: UUID
    let sourceTopologyRevision: UInt64
    let triangleCount: Int
    private var words: [UInt64]
    private(set) var selectedCount: Int
    private(set) var revision: UInt64
    private var revisionIdentity: UUID

    var version: FaceSelectionVersion {
        FaceSelectionVersion(identity: revisionIdentity, value: revision)
    }

    init(sourceTopologyID: UUID, sourceTopologyRevision: UInt64, triangleCount: Int,
         versionIdentity: UUID = UUID(), revision: UInt64 = 0) throws {
        guard triangleCount >= 0, triangleCount <= Self.maximumTriangleCount else {
            throw FaceSelectionError.triangleLimitExceeded
        }
        let (adjustedCount, overflow) = triangleCount.addingReportingOverflow(63)
        guard !overflow else { throw FaceSelectionError.allocationOverflow }
        let wordCount = adjustedCount / 64
        let (_, byteOverflow) = wordCount.multipliedReportingOverflow(by: MemoryLayout<UInt64>.stride)
        guard !byteOverflow else { throw FaceSelectionError.allocationOverflow }
        self.sourceTopologyID = sourceTopologyID
        self.sourceTopologyRevision = sourceTopologyRevision
        self.triangleCount = triangleCount
        words = Array(repeating: 0, count: wordCount)
        selectedCount = 0
        self.revision = revision
        revisionIdentity = versionIdentity
    }

    static func emptyUnavailable(sourceTopologyID: UUID, sourceTopologyRevision: UInt64) -> FaceSelection {
        // A zero-face value is the safe fallback when a source exceeds the selection limit.
        try! FaceSelection(sourceTopologyID: sourceTopologyID,
                           sourceTopologyRevision: sourceTopologyRevision,
                           triangleCount: 0)
    }

    func matches(_ mesh: EditableMesh) -> Bool {
        sourceTopologyID == mesh.runtime.topologyID
            && sourceTopologyRevision == mesh.runtime.topologyRevision
            && triangleCount == mesh.indices.count / 3
            && mesh.indices.count.isMultiple(of: 3)
    }

    func contains(_ faceID: Int) -> Bool {
        guard isValid(faceID) else { return false }
        let word = faceID >> 6
        let mask = UInt64(1) << UInt64(faceID & 63)
        return words[word] & mask != 0
    }

    @discardableResult
    mutating func set(_ faceID: Int, selected: Bool) throws -> Bool {
        guard isValid(faceID) else { throw FaceSelectionError.invalidFaceID }
        let word = faceID >> 6
        let mask = UInt64(1) << UInt64(faceID & 63)
        let wasSelected = words[word] & mask != 0
        guard wasSelected != selected else { return false }
        if selected {
            words[word] |= mask
            selectedCount += 1
        } else {
            words[word] &= ~mask
            selectedCount -= 1
        }
        advanceRevision()
        return true
    }

    @discardableResult
    mutating func toggle(_ faceID: Int) throws -> Bool {
        guard isValid(faceID) else { throw FaceSelectionError.invalidFaceID }
        return try set(faceID, selected: !contains(faceID))
    }

    @discardableResult
    mutating func replace(with faceID: Int?) throws -> Bool {
        guard let faceID else { return clear() }
        guard isValid(faceID) else { throw FaceSelectionError.invalidFaceID }
        if selectedCount == 1, contains(faceID) { return false }
        for index in words.indices { words[index] = 0 }
        words[faceID >> 6] = UInt64(1) << UInt64(faceID & 63)
        selectedCount = 1
        advanceRevision()
        return true
    }

    @discardableResult
    mutating func clear() -> Bool {
        guard selectedCount > 0 else { return false }
        for index in words.indices { words[index] = 0 }
        selectedCount = 0
        advanceRevision()
        return true
    }

    @discardableResult
    mutating func selectAll() -> Bool {
        guard triangleCount > 0, selectedCount != triangleCount else { return false }
        for index in words.indices { words[index] = .max }
        maskUnusedTailBits()
        selectedCount = triangleCount
        advanceRevision()
        return true
    }

    @discardableResult
    mutating func invert() -> Bool {
        guard triangleCount > 0 else { return false }
        for index in words.indices { words[index] = ~words[index] }
        maskUnusedTailBits()
        selectedCount = triangleCount - selectedCount
        advanceRevision()
        return true
    }

    @discardableResult
    mutating func formUnion(_ faceIDs: [Int]) throws -> Bool {
        guard faceIDs.allSatisfy(isValid) else { throw FaceSelectionError.invalidFaceID }
        var changed = false
        for faceID in faceIDs {
            let word = faceID >> 6
            let mask = UInt64(1) << UInt64(faceID & 63)
            guard words[word] & mask == 0 else { continue }
            words[word] |= mask
            selectedCount += 1
            changed = true
        }
        if changed { advanceRevision() }
        return changed
    }

    func selectedFaceIDs() -> [Int] {
        guard selectedCount > 0 else { return [] }
        var result: [Int] = []
        result.reserveCapacity(selectedCount)
        for (wordIndex, storedWord) in words.enumerated() {
            var word = storedWord
            while word != 0 {
                let bit = word.trailingZeroBitCount
                let faceID = wordIndex * 64 + bit
                if faceID < triangleCount { result.append(faceID) }
                word &= word - 1
            }
        }
        return result
    }

    func selectedIndices(from mesh: EditableMesh) throws -> [UInt32] {
        guard matches(mesh) else { throw FaceSelectionError.staleTopology }
        let (indexCount, overflow) = selectedCount.multipliedReportingOverflow(by: 3)
        guard !overflow else { throw FaceSelectionError.allocationOverflow }
        let (_, byteOverflow) = indexCount.multipliedReportingOverflow(by: MemoryLayout<UInt32>.stride)
        guard !byteOverflow else { throw FaceSelectionError.allocationOverflow }
        var result: [UInt32] = []
        result.reserveCapacity(indexCount)
        for faceID in selectedFaceIDs() {
            let (offset, offsetOverflow) = faceID.multipliedReportingOverflow(by: 3)
            let (lastOffset, lastOffsetOverflow) = offset.addingReportingOverflow(2)
            guard !offsetOverflow, !lastOffsetOverflow, offset >= 0,
                  lastOffset < mesh.indices.count else {
                throw FaceSelectionError.invalidFaceID
            }
            guard Int(mesh.indices[offset]) < mesh.vertices.count,
                  Int(mesh.indices[offset + 1]) < mesh.vertices.count,
                  Int(mesh.indices[offset + 2]) < mesh.vertices.count else {
                throw FaceSelectionError.invalidMesh
            }
            result.append(mesh.indices[offset])
            result.append(mesh.indices[offset + 1])
            result.append(mesh.indices[offset + 2])
        }
        return result
    }

    private func isValid(_ faceID: Int) -> Bool {
        faceID >= 0 && faceID < triangleCount
    }

    private mutating func maskUnusedTailBits() {
        let usedBits = triangleCount & 63
        guard usedBits != 0, !words.isEmpty else { return }
        words[words.count - 1] &= (UInt64(1) << UInt64(usedBits)) - 1
    }

    private mutating func advanceRevision() {
        if revision == .max {
            var nextIdentity = UUID()
            while nextIdentity == revisionIdentity { nextIdentity = UUID() }
            revisionIdentity = nextIdentity
            revision = 0
        } else {
            revision += 1
        }
    }
}

enum FaceSelectionConnectivity {
    static let maximumTriangleCount = 1_000_000

    static func connectedFaceIDs(mesh: EditableMesh, seeds: [Int]) throws -> [Int] {
        guard mesh.indices.count.isMultiple(of: 3) else { throw FaceSelectionError.invalidMesh }
        let triangleCount = mesh.indices.count / 3
        guard triangleCount <= maximumTriangleCount else { throw FaceSelectionError.connectedLimitExceeded }
        guard !seeds.isEmpty, seeds.allSatisfy({ $0 >= 0 && $0 < triangleCount }) else {
            throw FaceSelectionError.invalidFaceID
        }
        guard mesh.vertices.allSatisfy({ $0.position.allFinite && $0.normal.allFinite }) else {
            throw FaceSelectionError.invalidMesh
        }

        var unionFind = FaceSelectionUnionFind(count: triangleCount)
        var firstFaceByEdge: [DiagnosticEdgeKey: Int] = [:]
        let twiceAreaEpsilon = MeshDiagnosticTriangleRules.twiceAreaEpsilon(for: mesh)
        let (edgeCapacity, capacityOverflow) = triangleCount.multipliedReportingOverflow(by: 2)
        guard !capacityOverflow else { throw FaceSelectionError.allocationOverflow }
        firstFaceByEdge.reserveCapacity(edgeCapacity)

        for faceID in 0..<triangleCount {
            let (offset, offsetOverflow) = faceID.multipliedReportingOverflow(by: 3)
            let (lastOffset, lastOffsetOverflow) = offset.addingReportingOverflow(2)
            guard !offsetOverflow, !lastOffsetOverflow,
                  lastOffset < mesh.indices.count else { throw FaceSelectionError.invalidMesh }
            let a = mesh.indices[offset], b = mesh.indices[offset + 1], c = mesh.indices[offset + 2]
            guard a != b, b != c, c != a,
                  Int(a) < mesh.vertices.count, Int(b) < mesh.vertices.count, Int(c) < mesh.vertices.count,
                  !MeshDiagnosticTriangleRules.isDegenerate(
                    a, b, c, vertices: mesh.vertices, twiceAreaEpsilon: twiceAreaEpsilon) else {
                throw FaceSelectionError.invalidMesh
            }
            for edge in [DiagnosticEdgeKey(a, b), DiagnosticEdgeKey(b, c), DiagnosticEdgeKey(c, a)] {
                if let firstFace = firstFaceByEdge[edge] {
                    unionFind.union(faceID, firstFace)
                } else {
                    firstFaceByEdge[edge] = faceID
                }
            }
        }

        let seedRoots = Set(seeds.map { unionFind.find($0) })
        var result: [Int] = []
        result.reserveCapacity(triangleCount)
        for faceID in 0..<triangleCount where seedRoots.contains(unionFind.find(faceID)) {
            result.append(faceID)
        }
        return result
    }
}

private struct FaceSelectionUnionFind {
    private var parents: [Int]
    private var ranks: [UInt8]

    init(count: Int) {
        parents = Array(0..<count)
        ranks = Array(repeating: 0, count: count)
    }

    mutating func find(_ value: Int) -> Int {
        var root = value
        while parents[root] != root { root = parents[root] }
        var current = value
        while parents[current] != current {
            let next = parents[current]
            parents[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ first: Int, _ second: Int) {
        let a = find(first), b = find(second)
        guard a != b else { return }
        if ranks[a] < ranks[b] { parents[a] = b }
        else if ranks[a] > ranks[b] { parents[b] = a }
        else { parents[b] = a; ranks[a] &+= 1 }
    }
}

enum FaceSelectionError: Error, LocalizedError, Equatable {
    case invalidFaceID
    case staleTopology
    case invalidMesh
    case triangleLimitExceeded
    case connectedLimitExceeded
    case allocationOverflow
    case activeEdit
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidFaceID: "The selected face is outside the current mesh."
        case .staleTopology: "The face selection belongs to an older mesh topology."
        case .invalidMesh: "The mesh is not valid for face selection."
        case .triangleLimitExceeded: "The mesh has too many triangles for face selection."
        case .connectedLimitExceeded: "Select Connected supports up to 1,000,000 triangles."
        case .allocationOverflow: "The face selection would exceed a safe memory size."
        case .activeEdit: "Finish the active edit before changing face selection."
        case .unavailable: "Face selection is unavailable during the current operation."
        }
    }
}
