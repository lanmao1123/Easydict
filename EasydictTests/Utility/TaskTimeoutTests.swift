//
//  TaskTimeoutTests.swift
//  EasydictTests
//
//  Created by tisfeng on 2026/4/12.
//

import Foundation
import Testing

@testable import Easydict

// MARK: - TaskTimeoutTests

@Suite("Task Timeout", .tags(.utilities, .unit))
struct TaskTimeoutTests {
    @Test("Returns operation result before timeout", .tags(.utilities, .unit))
    func returnsOperationResultBeforeTimeout() async throws {
        let result = try await Task.withTimeout(seconds: 1) {
            try await Task.sleepThrowing(seconds: 0.01)
            return "done"
        }

        #expect(result == "done")
    }

    @Test("Throws timeout error when timeout elapses first", .tags(.utilities, .unit))
    func throwsTimeoutErrorWhenTimeoutElapsesFirst() async {
        await #expect(throws: TaskTimeoutError.self) {
            try await Task.withTimeout(seconds: 0.01) {
                try await Task.sleepThrowing(seconds: 1)
                return "late"
            }
        }
    }

    @Test("Propagates operation error without wrapping", .tags(.utilities, .unit))
    func propagatesOperationErrorWithoutWrapping() async {
        await #expect(throws: SampleError.self) {
            try await Task.withTimeout(seconds: 1) {
                throw SampleError.failed
            }
        }
    }

    @Test("Returns after timeout without waiting for blocking work", .tags(.utilities, .unit))
    func returnsAfterTimeoutWithoutWaitingForBlockingWork() async {
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: TaskTimeoutError.self) {
            try await Task.withTimeout(seconds: 0.01) {
                usleep(300_000)
                return "late"
            }
        }

        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .milliseconds(200))
    }

    @Test("Parent cancellation returns promptly even when operation ignores cancellation", .tags(.utilities, .unit))
    func parentCancellationDoesNotWaitForOperation() async {
        let gate = TimeoutTestGate()
        let task = Task {
            try await Task.withTimeout(seconds: 30) {
                await gate.wait()
                return "late"
            }
        }
        await gate.waitUntilStarted()
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        // Bound the test even if a regression makes cancellation wait for the operation.
        let fallback = Task {
            try? await Task.sleepThrowing(seconds: 1)
            await gate.release()
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(start.duration(to: clock.now) < .milliseconds(500))
        fallback.cancel()
        await gate.release()
        await fallback.value
    }

    @Test("An already cancelled parent never starts its operation", .tags(.utilities, .unit))
    func alreadyCancelledParentDoesNotStartOperation() async {
        let entryGate = TimeoutTestGate()
        let invocation = TimeoutTestGate()
        let task = Task {
            await entryGate.wait()
            return try await Task.withTimeout(seconds: 30) {
                await invocation.release()
                return "unexpected"
            }
        }
        await entryGate.waitUntilStarted()
        task.cancel()
        await entryGate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        let wasInvoked = await invocation.wasReleased
        #expect(!wasInvoked)
    }

    @Test("Throws timeout immediately when duration is zero or negative", .tags(.utilities, .unit))
    func throwsTimeoutImmediatelyWhenDurationIsZeroOrNegative() async {
        await #expect(throws: TaskTimeoutError.self) {
            try await Task.withTimeout(seconds: 0) {
                "done"
            }
        }

        await #expect(throws: TaskTimeoutError.self) {
            try await Task.withTimeout(seconds: -1) {
                "done"
            }
        }
    }
}

// MARK: - SampleError

private enum SampleError: Error {
    case failed
}

// MARK: - TimeoutTestGate

/// Suspends work independently of task cancellation, with a deterministic start signal.
private actor TimeoutTestGate {
    // MARK: Internal

    private(set) var wasReleased = false

    func wait() async {
        started = true
        observer?.resume()
        observer = nil
        guard !wasReleased else { return }
        await withCheckedContinuation { operation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        wasReleased = true
        operation?.resume()
        operation = nil
    }

    // MARK: Private

    private var started = false
    private var operation: CheckedContinuation<(), Never>?
    private var observer: CheckedContinuation<(), Never>?
}
