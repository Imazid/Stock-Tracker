import Foundation
import CryptoKit

public enum AuditActor: String, Codable, Sendable {
    case user, agent, system, copilot
}

public enum AuditKind: String, Codable, CaseIterable, Sendable {
    case portfolioCreated, portfolioReset, portfolioDeleted
    case agentCreated, agentRenamed, agentDeleted, agentPaused, agentResumed, agentStopped
    case strategyChanged, riskPolicyChanged, modeChanged, liveRequestRefused
    case killSwitchEngaged, killSwitchReleased
    case signalGenerated
    case proposalCreated, proposalBlocked, proposalApproved, proposalRejected, proposalExpired, proposalFailed
    case orderSubmitted, orderRejected, orderPartiallyFilled, orderFilled, orderCanceled, orderExpired
    case backtestRun

    public var title: String {
        switch self {
        case .portfolioCreated: return "Paper portfolio created"
        case .portfolioReset: return "Paper portfolio reset"
        case .portfolioDeleted: return "Paper portfolio deleted"
        case .agentCreated: return "Agent created"
        case .agentRenamed: return "Agent renamed"
        case .agentDeleted: return "Agent deleted"
        case .agentPaused: return "Agent paused"
        case .agentResumed: return "Agent resumed"
        case .agentStopped: return "Agent stopped"
        case .strategyChanged: return "Strategy changed"
        case .riskPolicyChanged: return "Risk limits changed"
        case .modeChanged: return "Mode changed"
        case .liveRequestRefused: return "Live trading refused"
        case .killSwitchEngaged: return "Kill switch turned on"
        case .killSwitchReleased: return "Kill switch turned off"
        case .signalGenerated: return "Signal"
        case .proposalCreated: return "Trade proposed"
        case .proposalBlocked: return "Trade blocked by risk rules"
        case .proposalApproved: return "Proposal approved"
        case .proposalRejected: return "Proposal rejected"
        case .proposalExpired: return "Proposal expired"
        case .proposalFailed: return "Proposal failed"
        case .orderSubmitted: return "Order submitted"
        case .orderRejected: return "Order rejected"
        case .orderPartiallyFilled: return "Order partly filled"
        case .orderFilled: return "Order filled"
        case .orderCanceled: return "Order cancelled"
        case .orderExpired: return "Order expired"
        case .backtestRun: return "Backtest run"
        }
    }
}

/// One line of the audit trail. Each event carries the hash of the one before it, so an
/// edited, removed or reordered event breaks the chain and `AuditLog.verify` says where.
public struct AuditEvent: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var sequence: Int
    public var time: Date
    public var actor: AuditActor
    public var kind: AuditKind
    public var summary: String
    public var mode: ExecutionMode?
    public var agentID: UUID?
    public var ledgerID: UUID?
    public var orderID: UUID?
    public var proposalID: UUID?
    public var instrumentID: String?
    public var details: [String: String]
    public var previousHash: String
    public var hash: String

    /// The text the hash covers. Time is taken to the millisecond so a save and reload
    /// can't change it.
    var canonical: String {
        let ms = Int64((time.timeIntervalSince1970 * 1_000).rounded())
        let detailText = details.keys.sorted().map { "\($0)=\(details[$0] ?? "")" }.joined(separator: ";")
        var parts: [String] = [previousHash, String(sequence), String(ms), actor.rawValue, kind.rawValue, summary]
        parts.append(mode?.rawValue ?? "")
        parts.append(agentID?.uuidString ?? "")
        parts.append(ledgerID?.uuidString ?? "")
        parts.append(orderID?.uuidString ?? "")
        parts.append(proposalID?.uuidString ?? "")
        parts.append(instrumentID ?? "")
        parts.append(detailText)
        return parts.joined(separator: "|")
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct AuditVerification: Equatable, Sendable {
    public var isIntact: Bool
    /// Sequence number of the first event that doesn't match, when the chain is broken.
    public var brokenAtSequence: Int?
    public var eventCount: Int
}

/// Append-only record of everything that changed money, orders, agents or limits.
/// There is no API to edit or delete an event.
public struct AuditLog: Codable, Sendable {
    public private(set) var events: [AuditEvent]
    /// Hash and sequence the stored events continue from, after old events are archived.
    public private(set) var baseHash: String
    public private(set) var baseSequence: Int

    public static let genesisHash = String(repeating: "0", count: 64)

    public init() {
        events = []
        baseHash = Self.genesisHash
        baseSequence = 0
    }

    public var lastHash: String { events.last?.hash ?? baseHash }
    public var nextSequence: Int { (events.last?.sequence ?? baseSequence) + 1 }

    @discardableResult
    public mutating func append(time: Date, actor: AuditActor, kind: AuditKind, summary: String,
                                mode: ExecutionMode? = nil, agentID: UUID? = nil, ledgerID: UUID? = nil,
                                orderID: UUID? = nil, proposalID: UUID? = nil, instrumentID: String? = nil,
                                details: [String: String] = [:]) -> AuditEvent {
        var event = AuditEvent(id: UUID(), sequence: nextSequence, time: time, actor: actor, kind: kind,
                               summary: summary, mode: mode, agentID: agentID, ledgerID: ledgerID,
                               orderID: orderID, proposalID: proposalID, instrumentID: instrumentID,
                               details: details, previousHash: lastHash, hash: "")
        event.hash = AuditEvent.digest(event.canonical)
        events.append(event)
        return event
    }

    /// Recomputes every hash from the base. Any tampering shows up as a break.
    public func verify() -> AuditVerification {
        var previous = baseHash
        var expected = baseSequence + 1
        for event in events {
            guard event.sequence == expected, event.previousHash == previous,
                  AuditEvent.digest(event.canonical) == event.hash else {
                return AuditVerification(isIntact: false, brokenAtSequence: event.sequence, eventCount: events.count)
            }
            previous = event.hash
            expected += 1
        }
        return AuditVerification(isIntact: true, brokenAtSequence: nil, eventCount: events.count)
    }

    /// Drops the oldest events beyond `limit`, keeping the chain verifiable from the new base.
    /// Returns what was removed so a caller can archive it.
    @discardableResult
    public mutating func archive(keepingLast limit: Int) -> [AuditEvent] {
        guard events.count > limit, limit > 0 else { return [] }
        let removed = Array(events.prefix(events.count - limit))
        if let last = removed.last {
            baseHash = last.hash
            baseSequence = last.sequence
        }
        events.removeFirst(removed.count)
        return removed
    }
}
