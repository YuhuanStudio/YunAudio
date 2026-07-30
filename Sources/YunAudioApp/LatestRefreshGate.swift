/// Collapses notifications received during one asynchronous refresh to the
/// newest refresh that can still observe them.
///
/// The first request starts work. Any number arriving before it finishes
/// become one latest rerun, so a notification storm cannot queue an unbounded
/// amount of expensive discovery work. Generations also make a result obsolete
/// when a synchronous refresh has already produced a newer snapshot.
struct LatestRefreshGate {
    struct Token: Equatable {
        fileprivate let generation: Int
    }

    enum Completion: Equatable {
        case obsolete
        case idle
        case start(Token)
    }

    private var generation = 0
    private var active: Token?
    private var pending: Token?

    mutating func request() -> Token? {
        generation &+= 1
        let token = Token(generation: generation)
        guard active == nil else {
            pending = token
            return nil
        }
        active = token
        return token
    }

    func accepts(_ token: Token) -> Bool {
        active == token
    }

    mutating func finish(_ token: Token) -> Completion {
        guard active == token else { return .obsolete }
        if let pending {
            active = pending
            self.pending = nil
            return .start(pending)
        }
        active = nil
        return .idle
    }

    mutating func invalidate() {
        generation &+= 1
        active = nil
        pending = nil
    }
}
