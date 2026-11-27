//
//  GatedDrawingSerializer.swift
//  KurnTests
//
//  Deterministic off-main `PaperNoteSession.DrawingSerializer` test double that
//  pauses each serialization until released, tracking concurrency and thread
//  isolation without wall-clock sleeps.
//

import Foundation
@testable import Kurn

final class GatedDrawingSerializer: @unchecked Sendable {
    private struct CallCountObserver {
        let minimumCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var active = 0
    private var maxActive = 0
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var countObservers: [CallCountObserver] = []
    private var observedMainThread: [Bool] = []

    var maxConcurrent: Int { lock.withLock { maxActive } }
    var callCount: Int { lock.withLock { calls } }
    var hasWaitingCall: Bool { lock.withLock { !waiters.isEmpty } }
    var ranOffMainThread: Bool {
        lock.withLock { !observedMainThread.isEmpty && observedMainThread.allSatisfy { !$0 } }
    }

    private nonisolated static func isCurrentThreadMain() -> Bool {
        Thread.isMainThread
    }

    func serialize(_ snapshot: PaperDrawingSnapshot) async -> Data {
        await withCheckedContinuation { continuation in
            let readyObservers: [CheckedContinuation<Void, Never>] = lock.withLock {
                calls += 1
                active += 1
                maxActive = max(maxActive, active)
                waiters.append(continuation)
                let currentCalls = calls
                let ready = countObservers.filter { currentCalls >= $0.minimumCount }.map(\.continuation)
                countObservers.removeAll { currentCalls >= $0.minimumCount }
                return ready
            }
            for observer in readyObservers {
                observer.resume()
            }
        }
        let data = await PaperNoteSession.serializeOffMain(snapshot) { snap in
            let onMain = Self.isCurrentThreadMain()
            self.lock.withLock { self.observedMainThread.append(onMain) }
            return snap.drawing.dataRepresentation()
        }
        lock.withLock {
            active -= 1
        }
        return data
    }

    func waitForCall(atLeast minimumCount: Int) async {
        await withCheckedContinuation { continuation in
            let alreadySatisfied: Bool = lock.withLock {
                if calls >= minimumCount {
                    return true
                }
                countObservers.append(CallCountObserver(minimumCount: minimumCount, continuation: continuation))
                return false
            }
            if alreadySatisfied {
                continuation.resume()
            }
        }
    }

    func releaseNext() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            guard !waiters.isEmpty else { return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}
