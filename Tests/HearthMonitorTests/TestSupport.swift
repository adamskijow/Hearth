// SPDX-License-Identifier: MIT

import Foundation
import SupervisorCore

final class MonitorFakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [String: HTTPOutcome] = [:]
    private var fallback: HTTPOutcome
    private var posts: [String] = []
    private var gets: [String] = []
    private var delayNanoseconds: UInt64 = 0

    init(default fallback: HTTPOutcome = .refused) {
        self.fallback = fallback
    }

    func set(_ url: URL, outcome: HTTPOutcome) {
        lock.withLock { outcomes[url.absoluteString] = outcome }
    }

    func setDelay(nanoseconds: UInt64) {
        lock.withLock { delayNanoseconds = nanoseconds }
    }

    func get(_ url: URL, timeout: TimeInterval) async -> HTTPOutcome {
        let (delay, outcome) = lock.withLock { () -> (UInt64, HTTPOutcome) in
            gets.append(url.absoluteString)
            return (delayNanoseconds, outcomes[url.absoluteString] ?? fallback)
        }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return outcome
    }

    func post(_ url: URL, body: Data, timeout: TimeInterval) async -> HTTPOutcome {
        lock.withLock {
            posts.append(url.absoluteString)
            return outcomes[url.absoluteString] ?? fallback
        }
    }

    func postCount(_ url: URL) -> Int {
        lock.withLock { posts.filter { $0 == url.absoluteString }.count }
    }

    func getCount(_ url: URL) -> Int {
        lock.withLock { gets.filter { $0 == url.absoluteString }.count }
    }
}
