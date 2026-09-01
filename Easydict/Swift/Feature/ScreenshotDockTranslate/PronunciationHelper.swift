//
//  PronunciationHelper.swift
//  Easydict
//
//  Created by agent on 2026/9/1.
//  Copyright © 2026 izual. All rights reserved.
//

import AVFoundation
import Defaults
import Foundation
import OpenAI

// MARK: - PronunciationSpeaker

/// Speaks the English source aloud with the built-in macOS voice — local
/// synthesis, no network, no permission prompts. Re-speaking interrupts the
/// current utterance, which is the natural retry behavior for a word.
@MainActor
enum PronunciationSpeaker {
    // MARK: Internal

    static func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        // Slightly below the default rate so a learner can follow the word.
        utterance.rate = 0.42 * AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
        logInfo("[Pronunciation] speaking, chars=\(text.count)")
    }

    // MARK: Private

    private static let synthesizer = AVSpeechSynthesizer()
}

// MARK: - PronunciationHelper

/// Generates the Chinese-character phonetic rendering ("克劳德" for Claude)
/// for short English sources in the dock translate panel — pure text, no
/// speech. Requests walk the user's AI services: free-tier OpenAI-compatible
/// endpoints first (Zhipu's free GLM model), then the remaining enabled
/// OpenAI-compatible services, and finally the local Claude Code CLI as the
/// offline fallback.
@MainActor
final class PronunciationHelper {
    // MARK: Internal

    static let shared = PronunciationHelper()

    func fetchPronunciation(for text: String) async throws -> String {
        let providers = Self.availableProviders()
        guard !providers.isEmpty else {
            throw QueryError(type: .api, message: "no pronunciation-capable service enabled")
        }

        var lastError = ""
        for provider in providers {
            do {
                let result = try await provider.fetch(text, systemPrompt: Self.systemPrompt)
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw QueryError(type: .noResult, message: "empty pronunciation")
                }
                logInfo("[Pronunciation] succeeded via \(provider.name), chars=\(trimmed.count)")
                return trimmed
            } catch {
                lastError = error.localizedDescription
                logWarn("[Pronunciation] provider \(provider.name) failed: \(lastError), trying next")
            }
        }
        throw QueryError(type: .api, message: lastError)
    }

    // MARK: Private

    private static let systemPrompt = """
    You are a pronunciation assistant. The user gives an English word or short phrase. \
    Reply with ONLY how to pronounce it, written as Chinese characters that approximate \
    the English sound (for example: Claude -> 克劳德, goroutine -> 呙入汀). \
    No explanations, no quotes, no punctuation, no IPA, no pinyin. \
    Keep it under 12 characters. If the input is not English, reply with an empty string.
    """

    /// Enabled AI services that can answer an arbitrary prompt, in user order:
    /// OpenAI-compatible HTTP services first, local Claude Code CLI last.
    private static func availableProviders() -> [PronunciationProvider] {
        let candidates = LocalStorage.shared().enabledServices(.main).filter { service in
            service.enabledQuery && service.enabledAutoQuery
        }

        var providers: [PronunciationProvider] = []
        for service in candidates {
            if let openAI = service as? BaseOpenAIService, !openAI.model.isEmpty {
                providers.append(
                    OpenAICompatiblePronunciationProvider(
                        name: service.serviceType().rawValue,
                        endpoint: openAI.endpoint,
                        apiKey: openAI.apiKey,
                        model: openAI.model
                    )
                )
            } else if service is ClaudeCodeService {
                providers.append(ClaudeCodePronunciationProvider(name: "claudeCode"))
            }
        }
        return providers
    }
}

// MARK: - PronunciationProvider

protocol PronunciationProvider {
    var name: String { get }
    func fetch(_ text: String, systemPrompt: String) async throws -> String
}

// MARK: - OpenAICompatiblePronunciationProvider

/// Non-streaming chat completion against an OpenAI-compatible endpoint.
struct OpenAICompatiblePronunciationProvider: PronunciationProvider {
    let name: String
    let endpoint: String
    let apiKey: String
    let model: String

    func fetch(_ text: String, systemPrompt: String) async throws -> String {
        guard let url = URL(string: endpoint), url.isValid else {
            throw QueryError(type: .parameter, message: "endpoint is invalid")
        }

        var messages: [ChatQuery.ChatCompletionMessageParam] = []
        typealias ChatRole = ChatQuery.ChatCompletionMessageParam.Role
        let pairs: [(ChatRole, String)] = [(.system, systemPrompt), (.user, text)]
        for (role, content) in pairs {
            guard let message = ChatQuery.ChatCompletionMessageParam(role: role, content: content)
            else {
                throw QueryError(type: .parameter, message: "failed to build chat message")
            }
            messages.append(message)
        }

        var query = ChatQuery(messages: messages, model: model, temperature: 0.2)
        query.stream = false

        var request = URLRequest(url: url, timeoutInterval: EZNetWorkTimeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        }
        request.httpBody = try JSONEncoder().encode(query)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200 ... 299).contains(http.statusCode) {
            throw QueryError(
                type: .api,
                message: "HTTP \(http.statusCode)",
                errorDataMessage: String(data: data, encoding: .utf8)
            )
        }

        let chatResult = try JSONDecoder().decode(ChatResult.self, from: data)
        return chatResult.choices.first?.message.content?.string ?? ""
    }
}

// MARK: - ClaudeCodePronunciationProvider

/// Local Claude Code CLI as the offline fallback.
struct ClaudeCodePronunciationProvider: PronunciationProvider {
    let name: String

    func fetch(_ text: String, systemPrompt: String) async throws -> String {
        let runner = ClaudeCodeRunner()
        let stream = runner.run(prompt: text, systemPrompt: systemPrompt)
        var collected = ""
        for try await chunk in stream {
            collected += chunk
        }
        return collected
    }
}
