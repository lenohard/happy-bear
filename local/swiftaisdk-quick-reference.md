# SwiftAISDK Playground - Quick Reference Card

## 🚀 Quick Start (2 minutes)

### 1. Set Your API Key
```bash
# In terminal
export OPENAI_API_KEY='sk-...'

# Or use .env file
echo "OPENAI_API_KEY=sk-..." > .env
```

### 2. Open & Run Playground
```bash
# Open in Xcode
open "/Users/senaca/Documents/swift-ai-sdk Playground/Playground.xcworkspace"

# Run: Cmd+Enter or ▶ button
```

### 3. Check Console Output
- Watch for ✅ (success) or ❌ (error) marks
- Token usage shown for each test

---

## 📋 Test Overview

| Test | Purpose | Cost | Time |
|------|---------|------|------|
| TEST 1 | Basic API connectivity | $0.00001 | 1s |
| TEST 2 | Real-time streaming | $0.00002 | 2s |
| TEST 3 | Structured JSON output | $0.00002 | 2s |
| TEST 4 | Provider comparison | $0.00005 | 5s |
| TEST 5 | **Batch title suggestion** | $0.00002 | 3s |
| TEST 6 | Collection categorization | $0.00003 | 2s |
| **TOTAL** | **All tests combined** | **~$0.001-0.005** | **~15s** |

---

## 🔧 Useful Code Snippets

### Quick Text Generation
```swift
let response = try await generateText(
    model: openai("gpt-4-mini"),
    prompt: "Your question here"
)
print(response.text)
```

### Streaming (Real-Time)
```swift
let stream = try await streamText(
    model: openai("gpt-4-mini"),
    prompt: "Your prompt"
)
for try await delta in stream.textStream {
    print(delta, terminator: "")
}
```

### Structured Data
```swift
struct MyData: Codable {
    let field1: String
    let field2: Int
}

let data = try await generateObject(
    model: openai("gpt-4-mini"),
    prompt: "Generate JSON...",
    type: MyData.self
)
```

### Multiple Providers
```swift
// OpenAI
openai("gpt-4-mini")

// Anthropic Claude
anthropic("claude-3-haiku-20240307")

// Google Gemini
google("gemini-2.0-flash")

// Groq (free tier)
groq("llama-70b-8192")
```

---

## 🧪 Testing Checklist

- [ ] **API Key Test**: Can you see "✅ OpenAI API key loaded"?
- [ ] **Connectivity Test** (TEST 1): Do you get a response about SwiftAISDK?
- [ ] **Streaming Test** (TEST 2): Does haiku appear word-by-word?
- [ ] **Structure Test** (TEST 3): Does audiobook suggestion parse correctly?
- [ ] **Provider Test** (TEST 4): Do all 3 providers return responses?
- [ ] **Real Use Case** (TEST 5): Do track titles get improved?
- [ ] **Categorization** (TEST 6): Is collection correctly categorized?

---

## ⚠️ Common Issues & Fixes

| Issue | Fix |
|-------|-----|
| "Module 'SwiftAISDK' not found" | Wait for `.build/` folder to complete, restart Xcode |
| "Invalid API key" | Check key doesn't have extra spaces or newlines |
| "Request timeout" | Check internet connection, try simpler prompt |
| "Rate limit exceeded" | Wait 60 seconds, use cheaper model (Haiku) |
| "JSON parsing error" | Ensure Codable struct matches AI response format exactly |
| "Task 'never completes'" | Network might be blocked; check Xcode console for errors |

---

## 💰 Cost Calculator

```
OpenAI GPT-4 Mini:
- Input:  $0.15 per 1M tokens (typical: 1-2 tokens per word)
- Output: $0.60 per 1M tokens

Example costs:
- 1 simple question: ~$0.00001
- Batch rename 100 tracks: ~$0.0002
- Batch rename 1000 tracks: ~$0.002
```

**Money Saving Tips**:
1. Use **Claude 3 Haiku** instead of GPT-4 (2x cheaper)
2. Use **Groq** for development (free tier)
3. Keep prompts concise
4. Batch operations (rename 100 at once vs 100 individual requests)

---

## 📊 Model Comparison

| Model | Speed | Quality | Cost | Best For |
|-------|-------|---------|------|----------|
| GPT-4 Mini | Fast | Good | $ | General purpose |
| Claude 3 Haiku | Very Fast | Good | $ | Budget-friendly |
| Gemini Flash | Very Fast | Good | $ | Competitive price |
| Groq Llama | Instant | Fair | FREE | Development/testing |

**Recommendation**: Start with **Groq** for testing (free), then use **Claude 3 Haiku** for production (cheapest quality option).

---

## 🎯 What to Test First

### Day 1: Basics
1. ✅ Set API key
2. ✅ Run TEST 1 (basic text)
3. ✅ Run TEST 2 (streaming)
4. ✅ Note response quality

### Day 2: Real Use Cases
1. ✅ Run TEST 5 (batch rename) with your actual poor track titles
2. ✅ Adjust prompt to get better suggestions
3. ✅ Test with 10, 50, 100 tracks
4. ✅ Measure cost for scaling

### Day 3: Provider Comparison
1. ✅ Run TEST 4 with multiple providers
2. ✅ Compare quality vs cost
3. ✅ Choose best provider for your app

### Day 4: Integration Planning
1. ✅ Document findings
2. ✅ Plan implementation in audiobook app
3. ✅ Consider user experience flow

---

## 📚 Documentation

- **SwiftAISDK Docs**: https://swift-ai-sdk-docs.vercel.app
- **Research Doc**: `/local/swiftaisdk-research.md`
- **Detailed Guide**: `/local/swiftaisdk-playground-guide.md`
- **Playground Code**: `/swift-ai-sdk Playground/Content.playground/Contents.swift`

---

## 🔑 Tips for Success

### ✅ DO
- Use environment variables for API keys (secure)
- Test with small batches first (cheaper)
- Monitor token usage in console output
- Check Xcode console for detailed errors
- Use streaming for user feedback on long operations
- Batch requests when possible (cheaper per operation)

### ❌ DON'T
- Hardcode API keys in code
- Run all tests at once on first run (confusing)
- Use expensive models for testing (use Groq/Haiku)
- Keep playground window closed while tests run
- Ignore error messages (read them carefully!)
- Leave tasks running - check if they complete in console

---

## 🎓 Learning Path

1. **Understand the concepts**: Read research doc
2. **See working examples**: View playground code
3. **Hands-on testing**: Run each TEST individually
4. **Real-world application**: Customize for your use case
5. **Optimize**: Find best provider/model/cost ratio
6. **Integrate**: Add to audiobook app

---

## 📞 When You're Ready to Integrate

Once playground testing is successful:

1. Create `AIService.swift` in audiobook app
2. Copy working code from playground tests
3. Add error handling and caching
4. Integrate into UI views
5. Add user cost warnings
6. Set up analytics for API usage

---

**Next Action**: Open playground in Xcode and run a single test!

```bash
open "/Users/senaca/Documents/swift-ai-sdk Playground/Playground.xcworkspace"
```
