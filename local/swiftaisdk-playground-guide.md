# SwiftAISDK Playground - Testing & Exploration Guide

## Quick Start

Your SPI Playground is already set up with SwiftAISDK imported. The playground structure:
- **Content.playground**: Your testing/exploration code
- **PlaygroundDependencies**: Automatically downloaded dependencies
- **Playground.xcworkspace**: IDE for interactive development

## Basic Setup

### 1. Check Available Providers

First, see what providers and models are available:

```swift
import SwiftAISDK

// List all available providers and models
print("SwiftAISDK loaded successfully!")
// Available providers: OpenAI, Anthropic, Google, Groq, xAI, etc.
```

### 2. Set Up API Keys

Create a `.env` file or use hardcoded keys (⚠️ only for testing):

```swift
// Option A: Direct (NOT recommended for production)
let openaiKey = "sk-your-api-key-here"

// Option B: From environment (better for playground)
let openaiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""

// Option C: From file
func loadAPIKey(from file: String) -> String {
    let path = FileManager.default.currentDirectoryPath + "/" + file
    if let key = try? String(contentsOfFile: path, encoding: .utf8) {
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return ""
}
```

## Testing Checklist

### ✅ Test 1: Basic Text Generation (OpenAI)

```swift
import SwiftAISDK

// 1. Initialize
let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""

// 2. Generate text
Task {
    do {
        let response = try await generateText(
            model: openai("gpt-4-mini"),
            prompt: "What is SwiftAISDK?"
        )
        print("Response:", response.text)
    } catch {
        print("Error:", error)
    }
}
```

**Expected Output**: Simple text response about SwiftAISDK

**Cost**: ~0.00001 USD

---

### ✅ Test 2: Streaming Response

```swift
import SwiftAISDK

Task {
    do {
        let stream = try await streamText(
            model: openai("gpt-4-mini"),
            prompt: "Write a haiku about audiobooks"
        )

        print("Streaming response:")
        for try await delta in stream.textStream {
            print(delta, terminator: "")
        }
        print("\n")

        // Access final metrics
        print("Tokens used: \(stream.usage?.totalTokens ?? 0)")
    } catch {
        print("Error:", error)
    }
}
```

**Expected Output**: Real-time text generation, token usage

**Cost**: ~0.00005 USD

---

### ✅ Test 3: Structured Object Generation

```swift
import SwiftAISDK

struct AudiobookMetadata: Codable {
    let title: String
    let author: String
    let estimatedDuration: Int  // minutes
    let genre: String
}

Task {
    do {
        let metadata = try await generateObject(
            model: openai("gpt-4-mini"),
            prompt: "Generate metadata for an audiobook titled 'The Great Gatsby'",
            type: AudiobookMetadata.self
        )

        print("Generated Metadata:")
        print("- Title: \(metadata.title)")
        print("- Author: \(metadata.author)")
        print("- Duration: \(metadata.estimatedDuration) mins")
        print("- Genre: \(metadata.genre)")
    } catch {
        print("Error:", error)
    }
}
```

**Expected Output**: Structured JSON parsed into Swift object

**Use Case**: Batch rename, categorization

**Cost**: ~0.00002 USD

---

### ✅ Test 4: Provider Switching (Cost Comparison)

```swift
import SwiftAISDK

struct ComparisonResult: Codable {
    let provider: String
    let model: String
    let response: String
    let tokensUsed: Int
}

let prompt = "Suggest a title for an audiobook chapter"

// Test different providers
Task {
    do {
        // OpenAI - GPT-4 Mini (cheap + good quality)
        let openaiResponse = try await generateText(
            model: openai("gpt-4-mini"),
            prompt: prompt
        )

        // Anthropic - Claude 3 Haiku (cheaper + good quality)
        let anthropicResponse = try await generateText(
            model: anthropic("claude-3-haiku-20240307"),
            prompt: prompt
        )

        // Google - Gemini Flash (competitive pricing)
        let geminiResponse = try await generateText(
            model: google("gemini-2.0-flash"),
            prompt: prompt
        )

        print("=== Provider Comparison ===")
        print("OpenAI: \(openaiResponse.text)")
        print("Anthropic: \(anthropicResponse.text)")
        print("Google: \(geminiResponse.text)")
    } catch {
        print("Error:", error)
    }
}
```

**What to Test**:
- Response quality comparison
- Speed differences
- Which provider works best for your use case

**Cost Ranking** (cheapest first):
1. Groq (free tier) - Llama 70B
2. Claude 3 Haiku - $0.25/1M input tokens
3. GPT-4 Mini - $0.15/1M input tokens
4. Google Gemini Flash - $0.075/1M input tokens

---

### ✅ Test 5: Tool Calling (Function Calling)

```swift
import SwiftAISDK

struct Tool {
    let name: String
    let description: String
    let parameters: [String: Any]
}

// Define tools your AI can call
let playbackTools = [
    Tool(
        name: "play_collection",
        description: "Play a collection by its name",
        parameters: ["collectionName": "string"]
    ),
    Tool(
        name: "skip_to_minute",
        description: "Skip to a specific minute in the current track",
        parameters: ["minute": "number"]
    ),
    Tool(
        name: "set_speed",
        description: "Set playback speed",
        parameters: ["speed": "number"]  // 0.5 to 2.0
    )
]

Task {
    do {
        let userCommand = "Play my audiobooks collection and set speed to 1.5x"

        // Note: Tool calling API depends on specific provider implementation
        // This is a conceptual example - check SwiftAISDK docs for actual syntax

        print("User command: \(userCommand)")
        print("Tools available: \(playbackTools.map { $0.name })")

        // The AI should identify which tools to call
        // Expected output: Play audiobooks collection, then set speed
    } catch {
        print("Error:", error)
    }
}
```

**What to Test**:
- Can AI correctly identify needed tools?
- Does tool calling syntax work with SwiftAISDK?
- How to handle tool responses?

---

### ✅ Test 6: For Your Audiobook App - Batch Title Suggestion

```swift
import SwiftAISDK

struct TrackTitleSuggestion: Codable {
    let originalTitle: String
    let suggestedTitle: String
    let confidence: Double  // 0.0 to 1.0
}

func suggestTrackTitles(for tracks: [String]) async throws -> [TrackTitleSuggestion] {
    let tracksFormatted = tracks.enumerated()
        .map { "\($0.offset + 1). \($0.element)" }
        .joined(separator: "\n")

    let prompt = """
    I have these audiobook track titles that are poorly named. Generate better, more descriptive titles.

    Current titles:
    \(tracksFormatted)

    Generate improved titles that are:
    - More descriptive
    - Consistent in style
    - Appropriate for audiobooks

    Return a JSON array with objects containing:
    - originalTitle: the original title
    - suggestedTitle: your improved version
    - confidence: 0.0 to 1.0 confidence in the suggestion
    """

    let suggestions = try await generateObject(
        model: anthropic("claude-3-haiku-20240307"),  // Cheapest + good quality
        prompt: prompt,
        type: [TrackTitleSuggestion].self
    )

    return suggestions
}

// Test with sample tracks
Task {
    let sampleTracks = [
        "Track 1",
        "Part 2 of something",
        "Ch03",
        "unknown title 4",
        "intro"
    ]

    do {
        let suggestions = try await suggestTrackTitles(for: sampleTracks)

        print("=== Title Suggestions ===")
        for suggestion in suggestions {
            print("'\(suggestion.originalTitle)' → '\(suggestion.suggestedTitle)'")
            print("  Confidence: \(String(format: "%.0f%%", suggestion.confidence * 100))")
        }
    } catch {
        print("Error:", error)
    }
}
```

**What This Tests**:
- Real-world use case for your app
- Structured output generation
- Cost-effective model choice
- User experience flow

**Estimated Cost**:
- 5 tracks: ~$0.00001
- 100 tracks: ~$0.0002
- 1000 tracks: ~$0.002

---

## Testing Strategy

### Phase 1: Setup & Basics (5 min)
```
☐ Verify playground loads SwiftAISDK
☐ Test basic generateText with OpenAI
☐ Check API key handling
```

### Phase 2: Provider Testing (15 min)
```
☐ Test GPT-4 Mini (speed + cost)
☐ Test Claude 3 Haiku (even cheaper)
☐ Test Gemini Flash (competitive pricing)
☐ Compare response quality
```

### Phase 3: Advanced Features (20 min)
```
☐ Test streaming (real-time feedback)
☐ Test structured output (JSON objects)
☐ Test tool calling (if available)
```

### Phase 4: Real-World Scenario (15 min)
```
☐ Implement batch title suggestion
☐ Implement collection categorization
☐ Measure cost per operation
```

---

## Debugging Tips

### Check Compilation
```swift
// This will show any compile errors
import SwiftAISDK

print("If this prints, SwiftAISDK compiled successfully!")
```

### API Key Issues
```swift
let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
if apiKey.isEmpty {
    print("⚠️ WARNING: OPENAI_API_KEY not set")
    print("Set it with: export OPENAI_API_KEY='your-key'")
} else {
    print("✅ API key found (length: \(apiKey.count))")
}
```

### Network Issues
```swift
Task {
    do {
        let response = try await generateText(
            model: openai("gpt-4-mini"),
            prompt: "Test"
        )
        print("✅ Network connection OK")
    } catch {
        print("❌ Network error:", error.localizedDescription)
    }
}
```

### Token Usage Tracking
```swift
// Most responses include usage information
Task {
    do {
        let response = try await generateText(
            model: openai("gpt-4-mini"),
            prompt: "What is 2+2?"
        )

        // Print detailed token usage
        if let usage = response.usage {
            print("Input tokens: \(usage.inputTokens)")
            print("Output tokens: \(usage.outputTokens)")
            print("Total tokens: \(usage.totalTokens)")
        }
    } catch {
        print("Error:", error)
    }
}
```

---

## Cost Monitoring

Create a simple cost tracker:

```swift
import SwiftAISDK

struct TokenUsageTracker {
    private var totalTokens = 0
    private var totalCost = 0.0

    // OpenAI GPT-4 Mini pricing
    let inputCostPer1M = 0.15
    let outputCostPer1M = 0.60

    mutating func track(response: GenerateTextResponse) {
        if let usage = response.usage {
            totalTokens += usage.totalTokens

            let inputCost = Double(usage.inputTokens) * (inputCostPer1M / 1_000_000)
            let outputCost = Double(usage.outputTokens) * (outputCostPer1M / 1_000_000)

            totalCost += (inputCost + outputCost)
        }
    }

    func printSummary() {
        print("=== Token Usage Summary ===")
        print("Total Tokens: \(totalTokens)")
        print("Estimated Cost: $\(String(format: "%.4f", totalCost))")
    }
}

// Usage
var tracker = TokenUsageTracker()

Task {
    for i in 0..<5 {
        let response = try await generateText(
            model: openai("gpt-4-mini"),
            prompt: "Short response please"
        )

        tracker.track(response: response)
    }

    tracker.printSummary()
}
```

---

## Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| "Module not found: SwiftAISDK" | Wait for PlaygroundDependencies to build (check .build folder) |
| "API key invalid" | Check key doesn't have extra spaces, verify correct provider |
| "Rate limited" | Wait a few seconds, implement exponential backoff |
| "Timeout" | Check internet connection, try with simpler prompt |
| "Structured output parsing fails" | Verify JSON format matches Codable struct exactly |

---

## Next Steps

1. **Complete Test Phase 1** (Basic connectivity)
2. **Run Test Phase 2** (Provider comparison)
3. **Benchmark Phase 3** (Cost vs quality)
4. **Implement Phase 4** (Real audiobook use case)
5. **Document findings** in `swiftaisdk-research.md`

Once you confirm which provider/model works best, we can integrate it into your actual audiobook player app!

---

## Resources

- **SwiftAISDK Docs**: https://swift-ai-sdk-docs.vercel.app
- **GitHub Repo**: https://github.com/teunlao/swift-ai-sdk
- **API Pricing**: Check individual provider websites for latest rates
- **Playground Tips**: https://swiftpackageindex.com/try-in-a-playground
