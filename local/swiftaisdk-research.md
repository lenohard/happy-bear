# SwiftAISDK Research & Integration Guide

## Overview

**SwiftAISDK** is a unified AI framework for iOS that provides a single API to interact with 28+ AI providers. It's based on the Vercel AI SDK and focuses on making it easy to build AI-powered features without vendor lock-in.

**Repository**: https://github.com/teunlao/swift-ai-sdk
**Documentation**: https://swift-ai-sdk-docs.vercel.app
**License**: Apache 2.0
**Status**: Active development (497 commits, 5 releases)

---

## Key Features

### 1. **Multi-Provider Support** (28+ providers)
- **OpenAI**: GPT-4.5, GPT-4, GPT-3.5
- **Anthropic**: Claude 3 (Opus, Sonnet, Haiku)
- **Google**: Gemini (2, 2.0 Flash, Pro)
- **Meta**: Llama 2, 3
- **Others**: Groq, xAI, Mistral, Perplexity, HuggingFace, AWS Bedrock, and more

**Benefit**: Write code once, switch providers without changing function signatures.

### 2. **Streaming & Non-Streaming**
- Real-time text generation with streaming
- Complete response generation
- Type-safe token handling

```swift
// Streaming example
let stream = try streamText(
  model: openai("gpt-4"),
  prompt: "Your prompt here"
)

for try await delta in stream.textStream {
  print(delta, terminator: "")  // Real-time output
}
```

### 3. **Structured Data Generation**
- Generate type-safe objects from AI responses
- Uses JSON schemas and Codable types
- Perfect for extracting metadata, parsing, batch operations

```swift
// Example: Generate metadata for audiobook
struct AudiobookMetadata: Codable {
  let title: String
  let author: String
  let genre: String
  let duration: Double
}

let metadata = try generateObject(
  model: anthropic("claude-3-sonnet"),
  prompt: "Analyze this audiobook description...",
  type: AudiobookMetadata.self
)
```

### 4. **Tool Calling (Function Calling)**
- Integrate external functions and tools
- MCP (Model Context Protocol) support
- Enable agents to take actions

```swift
// Example: AI assistant that can control playback
let tools: [Tool] = [
  Tool(name: "play", description: "Play the current track"),
  Tool(name: "pause", description: "Pause playback"),
  Tool(name: "next", description: "Skip to next track"),
  Tool(name: "set_speed", description: "Set playback speed", parameters: [...])
]

let response = try generateText(
  model: openai("gpt-4"),
  tools: tools,
  prompt: "Play the next audiobook"
)
```

### 5. **Middleware System**
- Extensible request/response processing
- Custom logging, monitoring, rate limiting
- Request preprocessing and response validation

```swift
let middleware: [Middleware] = [
  LoggingMiddleware(),
  RateLimitMiddleware(requestsPerMinute: 60),
  CustomValidationMiddleware()
]

let response = try generateText(
  model: openai("gpt-4"),
  middleware: middleware,
  prompt: "Your prompt"
)
```

---

## Installation

### Step 1: Add to Package.swift
```swift
.package(url: "https://github.com/teunlao/swift-ai-sdk.git", from: "0.4.0")
```

### Step 2: Add to Your Target
```swift
.target(
  name: "AudiobookPlayer",
  dependencies: [
    "SwiftAISDK",
    .product(name: "OpenAIProvider", package: "swift-ai-sdk"),
    // Add other providers as needed
  ]
)
```

### Step 3: Configure API Keys
Store API keys securely in Keychain:
```swift
import SwiftAISDK

let apiKey = try KeychainStore.retrieve(key: "OPENAI_API_KEY")
let client = OpenAIClient(apiKey: apiKey)
```

---

## Integration Opportunities for Audiobook Player

### 1. **Batch Rename Collections & Tracks** (Your AI feature)
**Use Case**: Let users rename multiple tracks using AI-generated titles based on metadata

```swift
// Example: Generate better track titles
struct TrackTitleSuggestion: Codable {
  let currentTitle: String
  let suggestedTitle: String
  let reasoning: String
}

func suggestTrackTitles(tracks: [AudiobookTrack]) async throws -> [TrackTitleSuggestion] {
  let prompt = """
  I have these audiobook track titles. Generate better, more descriptive titles.
  Current titles: \(tracks.map { $0.title }.joined(separator: ", "))

  Return a JSON array with { currentTitle, suggestedTitle, reasoning }
  """

  let suggestions = try generateObject(
    model: anthropic("claude-3-haiku"),  // Cheap, fast model
    prompt: prompt,
    type: [TrackTitleSuggestion].self
  )

  return suggestions
}
```

**Cost Estimate**: ~0.002-0.005 USD per 100 tracks (using Claude Haiku)

### 2. **Smart Collection Organization**
**Use Case**: AI categorizes collections into genres, organizes by theme

```swift
struct CollectionCategory: Codable {
  let name: String
  let suggestedName: String
  let category: String  // "Fiction", "NonFiction", "Podcast", "Educational"
  let description: String
}

func categorizeCollection(_ collection: AudiobookCollection) async throws -> CollectionCategory {
  let trackSummary = collection.tracks.prefix(5).map { "\($0.title) - \($0.duration)s" }

  let prompt = """
  Based on these track titles from a collection:
  \(trackSummary.joined(separator: "\n"))

  Suggest a category and improved collection name.
  Return JSON: { name, suggestedName, category, description }
  """

  return try generateObject(
    model: openai("gpt-4-mini"),
    prompt: prompt,
    type: CollectionCategory.self
  )
}
```

### 3. **Interactive Playback Assistant (Siri Integration)**
**Use Case**: Natural language commands via voice

```swift
let tools: [Tool] = [
  Tool(name: "play_collection", description: "Play a collection by name"),
  Tool(name: "jump_to_track", description: "Jump to a specific track"),
  Tool(name: "set_playback_speed", description: "Set playback speed"),
  Tool(name: "search_collections", description: "Search for collections")
]

// User says: "Skip ahead 5 minutes and reduce speed to 0.75x"
let userCommand = "Skip ahead 5 minutes and reduce speed to 0.75x"
let result = try generateText(
  model: openai("gpt-4-mini"),
  tools: tools,
  prompt: "Execute this command: \(userCommand)"
)
```

### 4. **Content Summarization**
**Use Case**: Generate summaries for long audiobooks

```swift
func generateChapterSummary(
  trackTitle: String,
  duration: Double
) async throws -> String {
  let prompt = """
  Create a 2-3 sentence summary for an audiobook chapter:
  Title: \(trackTitle)
  Estimated Duration: \(Int(duration / 60)) minutes

  Make it engaging and informative.
  """

  let response = try streamText(
    model: anthropic("claude-3-haiku"),
    prompt: prompt
  )

  var summary = ""
  for try await delta in response.textStream {
    summary += delta
  }
  return summary
}
```

### 5. **Smart Search & Discovery**
**Use Case**: Natural language search across library

```swift
struct SearchResult: Codable {
  let collections: [String]
  let tracks: [String]
  let reasoning: String
}

func semanticSearch(query: String, library: [AudiobookCollection]) async throws -> SearchResult {
  let libraryDescription = library.map {
    "Collection: \($0.title) - Tracks: \($0.tracks.map { $0.title }.joined(separator: ", "))"
  }.joined(separator: "\n")

  let prompt = """
  User wants: \(query)

  Available collections:
  \(libraryDescription)

  Suggest relevant collections and tracks.
  Return JSON: { collections, tracks, reasoning }
  """

  return try generateObject(
    model: openai("gpt-4-mini"),
    prompt: prompt,
    type: SearchResult.self
  )
}
```

---

## Cost Analysis

| Provider | Model | Cost per 1M tokens | Best For |
|----------|-------|-------------------|----------|
| OpenAI | GPT-4 Turbo | $10 / $30 (I/O) | High quality, complex tasks |
| OpenAI | GPT-4 Mini | $0.15 / $0.60 | Fast, simple tasks |
| Anthropic | Claude 3 Opus | $15 / $75 | Complex reasoning |
| Anthropic | Claude 3 Haiku | $0.25 / $1.25 | Budget-friendly, good quality |
| Groq | Llama 70B | Free tier | Development, testing |
| Google | Gemini Flash | $0.075 / $0.30 | Quick tasks, competitive pricing |

**Recommendation for Audiobook Player**:
- **Batch rename**: Claude 3 Haiku ($0.005 per 100 titles)
- **Collection categorization**: GPT-4 Mini ($0.001 per operation)
- **Summarization**: Claude 3 Haiku (cheapest + good quality)
- **Smart search**: GPT-4 Mini or Gemini Flash (speed + cost balance)

---

## Security Considerations

### API Key Storage
```swift
import SwiftAISDK

enum APIKeyManager {
  static func storeKey(_ key: String, for provider: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.audiobook.ai.\(provider)",
      kSecValueData as String: key.data(using: .utf8)!
    ]

    SecItemAdd(query as CFDictionary, nil)
  }

  static func retrieveKey(for provider: String) throws -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.audiobook.ai.\(provider)",
      kSecReturnData as String: true
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
          let data = result as? Data,
          let key = String(data: data, encoding: .utf8) else {
      throw KeychainError.itemNotFound
    }
    return key
  }
}
```

### Rate Limiting & Throttling
```swift
class RateLimitMiddleware: Middleware {
  let requestsPerMinute = 60
  var requestTimestamps: [Date] = []

  func process(_ request: inout AIRequest) async throws {
    let now = Date()
    requestTimestamps = requestTimestamps.filter {
      now.timeIntervalSince($0) < 60
    }

    if requestTimestamps.count >= requestsPerMinute {
      throw AIError.rateLimited
    }

    requestTimestamps.append(now)
  }
}
```

### Cost Control
```swift
// Implement token budget tracking
class TokenBudgetMiddleware: Middleware {
  let monthlyTokenBudget = 100_000  // tokens
  var tokensUsed = 0

  func process(_ response: inout AIResponse) async throws {
    tokensUsed += response.usage.totalTokens

    if tokensUsed > monthlyTokenBudget {
      throw AIError.budgetExceeded(
        used: tokensUsed,
        limit: monthlyTokenBudget
      )
    }
  }
}
```

---

## Testing & Development

The SwiftAISDK has 2,243 tests with 79.5% code coverage. For development:

```swift
// Use free tier Groq for testing
let testModel = groq("llama-70b")  // Free, fast for development

// Or use Claude's API with test mode
let mockModel = MockAIModel(
  responses: ["Test response 1", "Test response 2"]
)
```

---

## Potential Issues & Workarounds

### 1. **iOS 16 Compatibility**
- SwiftAISDK may require iOS 17+ (check documentation)
- Your app supports iOS 16+
- **Solution**: Wait for version confirmation or vendor support for iOS 16

### 2. **Network & Offline Mode**
- SwiftAISDK requires internet connection
- **Solution**: Cache responses locally, gracefully degrade when offline

### 3. **Privacy & On-Device Processing**
- SwiftAISDK sends data to external APIs
- **Solution**: For privacy-sensitive operations, use on-device models (Core ML)

### 4. **Token Consumption**
- Uncontrolled API calls can become expensive
- **Solution**: Implement token budgets, rate limiting, and user warnings

---

## Recommended Implementation Plan

### Phase 1: Foundation (Low Risk)
1. Add SwiftAISDK to project
2. Implement secure API key storage
3. Create AI service wrapper with rate limiting
4. Add error handling middleware

### Phase 2: Batch Rename Feature (Medium Risk)
1. Implement title suggestion using Claude 3 Haiku
2. Add "Suggest Titles" button to collection detail view
3. Show suggestions with cost preview before applying
4. Store suggestion history locally

### Phase 3: Advanced Features (Higher Cost)
1. Smart collection categorization
2. Chapter summaries
3. Semantic search
4. Playback assistant

### Phase 4: Monetization (Optional)
- If app goes to App Store, consider:
  - **Subscription model**: Include AI features in premium tier
  - **Pay-per-use**: Users buy AI credits
  - **Hybrid**: Free tier + premium features

---

## Quick Start Example

```swift
import SwiftAISDK
import OpenAIProvider

// 1. Initialize client
let apiKey = try APIKeyManager.retrieveKey(for: "openai")
let client = OpenAIClient(apiKey: apiKey)

// 2. Create service
class AIAudiobookService {
  func suggestTitle(for track: AudiobookTrack) async throws -> String {
    let response = try await generateText(
      model: openai("gpt-4-mini"),
      prompt: "Suggest a better title for: \(track.title)"
    )
    return response.text
  }

  func categorizeCollection(_ collection: AudiobookCollection) async throws -> String {
    struct Category: Codable {
      let category: String
    }

    let result = try await generateObject(
      model: anthropic("claude-3-haiku"),
      prompt: "Categorize this collection: \(collection.title)",
      type: Category.self
    )
    return result.category
  }
}

// 3. Use in UI
@StateObject var aiService = AIAudiobookService()

Button("Suggest Better Title") {
  Task {
    let newTitle = try await aiService.suggestTitle(for: track)
    // Update UI with newTitle
  }
}
```

---

## References & Resources

- **Official Docs**: https://swift-ai-sdk-docs.vercel.app
- **GitHub Repo**: https://github.com/teunlao/swift-ai-sdk
- **Provider Guides**: See docs for provider-specific configuration
- **Examples**: GitHub repo includes examples for each provider

---

## Next Steps

### For You:
1. Review this research document
2. Decide which AI features align with your product vision
3. Test with your ai_gateway vs SwiftAISDK approach
4. Consider cost/benefit of each integration

### Questions to Consider:
1. **In-App vs External Server**: Should AI run on-device (Core ML) or cloud-based?
2. **Monetization**: Will AI features be free for all users or premium-only?
3. **Provider Preference**: OpenAI (expensive, best quality) vs Anthropic (Claude, good balance) vs budget options?
4. **User Consent**: Need to show users that AI features send data to external services?

---

**Last Updated**: 2025-11-07
**Research Status**: ✅ Complete - Ready for implementation discussion
