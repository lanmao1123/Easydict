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
/// speech. Requests walk the user's AI services: the local Claude Code CLI
/// first (subscription-priced, measurably better at phonetic rendering),
/// then the enabled OpenAI-compatible services (free-tier GLM etc.) as the
/// fallback for machines without the CLI.
@MainActor
final class PronunciationHelper {
    // MARK: Internal

    static let shared = PronunciationHelper()

    // Few-shot examples matter: small free models (glm-4-flash) produced
    // wrong syllables for "Reasoning" (「里森」) without them. The r->l rule
    // matters too: an example rendering Run- as 「拉」 taught models to output
    // 「拉格」 for RAG. Users can override the whole prompt from Settings →
    // Screenshot (an empty override falls back here).
    static let defaultPrompt = """
    You are a pronunciation assistant. The user gives an English word or short phrase, \
    often a software-engineering term (framework, library or tool name); prefer the \
    pronunciation actually used in the developer community. \
    Reply with ONLY its pronunciation written as Chinese characters that approximate the \
    STANDARD English sound, syllable by syllable — never drop or merge syllables, and \
    keep word endings like -ing, -tion, -ous. \
    The English r-sound must use an r-initial Chinese character (瑞、若、热、软), \
    never an l-initial one (拉、勒、里、兰).

    Examples:
    Claude -> 克劳德
    goroutine -> 呙入汀
    Reasoning -> 瑞森宁
    RAG -> 瑞格
    engineering -> 恩吉尼厄灵

    No explanations, no quotes, no punctuation, no IPA, no pinyin. \
    Keep it under 16 characters. If the input is not English, reply with an empty string.
    """

    func fetchPronunciation(for text: String) async throws -> String {
        let providers = Self.availableProviders()
        guard !providers.isEmpty else {
            throw QueryError(type: .api, message: "no pronunciation-capable service enabled")
        }

        var lastError = ""
        for provider in providers {
            do {
                let result = try await provider.fetch(text, systemPrompt: Self.activePrompt)
                let trimmed = result
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "。．.!?！？；;：:\"'“”‘’「」『』`"))
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

    /// The effective prompt: the user's Settings override when non-empty.
    private static var activePrompt: String {
        let custom = Defaults[.dockPronunciationPrompt]
        return custom.isEmpty ? defaultPrompt : custom
    }

    /// Enabled AI services that can answer an arbitrary prompt. The local
    /// Claude Code CLI goes first on purpose: free-tier GLM models measurably
    /// garble syllables (Runnable -> 「兰尼布尔」/「朗能」) while 4.5-flash
    /// returns empty bodies and 4.7-flash sits under model-level rate limits.
    /// Claude Code runs inside the user's subscription, so quality costs
    /// nothing extra; the OpenAI-compatible services remain the fallback for
    /// machines without the CLI.
    private static func availableProviders() -> [PronunciationProvider] {
        let candidates = LocalStorage.shared().enabledServices(.main).filter { service in
            service.enabledQuery && service.enabledAutoQuery
        }

        var claudeProviders: [PronunciationProvider] = []
        var httpProviders: [PronunciationProvider] = []
        for service in candidates {
            if let openAI = service as? BaseOpenAIService, !openAI.model.isEmpty {
                httpProviders.append(
                    OpenAICompatiblePronunciationProvider(
                        name: service.serviceType().rawValue,
                        endpoint: openAI.endpoint,
                        apiKey: openAI.apiKey,
                        model: openAI.model
                    )
                )
            } else if service is ClaudeCodeService {
                claudeProviders.append(ClaudeCodePronunciationProvider(name: "claudeCode"))
            }
        }
        return claudeProviders + httpProviders
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

        var query = ChatQuery(messages: messages, model: model, temperature: 0.1)
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
