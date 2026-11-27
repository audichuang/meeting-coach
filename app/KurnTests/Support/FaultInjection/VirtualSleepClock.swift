//
//  VirtualSleepClock.swift
//  KurnTests
//
//  Deterministic suspending `SleepClock` that holds sleepers until a test
//  advances virtual time via `advance(by:)`, enabling zero-wall-clock tests
//  of debounce, max-wait, and retry scheduling.
//

import Foundation
import KurnCore

final class VirtualSleepClock: SleepClock, @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct WaiterCountObserver {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentTime: TimeInterval = 0
    private var waiters: [Waiter] = []
    private var countObservers: [WaiterCountObserver] = []

    var activeWaiterCount: Int { lock.withLock { waiters.count } }

    func sleep(seconds: TimeInterval) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (shouldCancel, satisfiedObservers): (Bool, [CheckedContinuation<Void, Never>]) = lock.withLock {
                    if Task.isCancelled { return (true, []) }
                    waiters.append(Waiter(id: waiterID, deadline: currentTime + seconds, continuation: continuation))
                    let count = waiters.count
                    let ready = countObservers.filter { count >= $0.minimumCount }.map(\.continuation)
                    countObservers.removeAll { count >= $0.minimumCount }
                    return (false, ready)
                }
                for observer in satisfiedObservers {
                    observer.resume()
                }
                if shouldCancel {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let cancelled: CheckedContinuation<Void, Error>? = self.lock.withLock {
                guard let index = self.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                return self.waiters.remove(at: index).continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Suspends until at least `minimumCount` sleepers are registered on this clock.
    func waitForWaiters(atLeast minimumCount: Int) async {
        await withCheckedContinuation { continuation in
            let alreadySatisfied: Bool = lock.withLock {
                if waiters.count >= minimumCount {
                    return true
                }
                countObservers.append(WaiterCountObserver(minimumCount: minimumCount, continuation: continuation))
                return false
            }
            if alreadySatisfied {
                continuation.resume()
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            currentTime += seconds
            let due = waiters.filter { $0.deadline <= currentTime + 1e-9 }
            waiters.removeAll { $0.deadline <= currentTime + 1e-9 }
            return due.map(\.continuation)
        }
        for continuation in ready {
            continuation.resume()
        }
    }
}
