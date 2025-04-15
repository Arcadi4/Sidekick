//
//  Provider.swift
//  Sidekick
//
//  Created by John Bean on 4/15/25.
//

import Foundation

/// Providers that serve models
public struct Provider: Identifiable {
    
    public var id: String { self.name }
    
    /// A `String` for the provider's name
    public var name: String
    /// A `URL` for the provider's OpenAI compatible endpoint
    public var endpointUrl: URL
    
    /// A list of popular providers
    public static let popularProviders: [Provider] = [
        Provider(
            name: "Aliyun Bailian (China)",
            endpointUrl: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        ),
        Provider(
            name: "Anthropic",
            endpointUrl: URL(string: "https://api.anthropic.com/v1")!
        ),
        Provider(
            name: "DeepSeek",
            endpointUrl: URL(string: "https://api.deepseek.com/v1")!
        ),
        Provider(
            name: "Google AI Studio",
            endpointUrl: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        ),
        Provider(
            name: "Groq",
            endpointUrl: URL(string: "https://api.groq.com/openai/v1")!
        ),
        Provider(
            name: "LM Studio",
            endpointUrl: URL(string: "http://localhost:1234/v1")!
        ),
        Provider(
            name: "Mistral",
            endpointUrl: URL(string: "https://api.mistral.ai/v1")!
        ),
        Provider(
            name: "Ollama",
            endpointUrl: URL(string: "http://localhost:11434/v1")!
        ),
        Provider(
            name: "OpenAI",
            endpointUrl: URL(string: "https://api.openai.com/v1")!
        ),
        Provider(
            name: "OpenRouter",
            endpointUrl: URL(string: "https://openrouter.ai/api/v1")!
        )
    ]
}
