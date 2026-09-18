//
//  ServiceTests.swift
//  EasydictTests
//
//  Created by tisfeng on 2025/12/20.
//  Copyright © 2025 izual. All rights reserved.
//

import Testing

@testable import Easydict

/// Integration tests that verify each registered service can translate a sample input.
@Suite("Service Translation Validation", .tags(.integration))
struct ServiceTests {
    // MARK: Internal

    /// Validates that every enabled service returns a successful translation result.
    ///
    /// The upstream version swept ALL registered services, which just waved
    /// red on this fork for providers that were never configured (missing
    /// keys, Codex quota, CLI PATH gaps, keyless Google rejections). What
    /// matters here is that the services this installation actually enables
    /// keep working.
    @Test("Validate All Services Translation", .tags(.integration))
    func testAllServicesValidateTranslation() async throws {
        let services = LocalStorage.shared().enabledServices(.main)

        #expect(!services.isEmpty, "No enabled services to validate.")

        for service in services {
            try await validate(service: service)
        }
    }

    // MARK: Private

    /// Validates a single service and records a failure if translation fails.
    private func validate(service: QueryService) async throws {
        let result = await validationResult(for: service)
        guard let error = result.error else { return }

        // The Apple service's optional Shortcuts-based flow requires the
        // "Easydict-Translate" shortcut to be installed; without it there is
        // nothing to validate on this machine.
        let message = error.localizedDescription
        if message.contains("Shortcuts Events") || message.contains("shortcut") {
            logInfo("[ServiceTests] skip service \(service.serviceType().rawValue): missing optional shortcut")
            return
        }

        #expect(
            result.error == nil,
            "Service [\(service.serviceType().rawValue)] failed validation: \(message)"
        )
    }

    /// Returns the validation result for a service, using dictionary-friendly input when needed.
    private func validationResult(for service: QueryService) async -> QueryResult {
        if service is AppleDictionary {
            return await validateTranslation(
                service,
                text: "good",
                from: .english,
                to: .english
            )
        }

        return await service.validate()
    }

    /// Runs a translation request and returns the final query result.
    private func validateTranslation(
        _ service: QueryService,
        text: String,
        from: Language,
        to: Language
    ) async
        -> QueryResult {
        let currentResult = service.resetServiceResult()

        do {
            return try await service.translate(text, from: from, to: to)
        } catch {
            let result = service.result ?? currentResult
            if result.error == nil {
                result.error = QueryError.queryError(from: error)
            }
            return result
        }
    }
}
