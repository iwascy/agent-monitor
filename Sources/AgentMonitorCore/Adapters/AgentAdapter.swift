import Foundation

public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    var watchPaths: [URL] { get }
    func scan() throws -> [AgentSession]
}
