# Why Custom URL Schemes vs "oob" Redirect URI

## The Core Difference

### Custom URL Scheme (`com.wdh.audiobook://oauth-callback`)
**How it works**:
1. User authorizes on Baidu's page
2. Baidu redirects to: `com.wdh.audiobook://oauth-callback?code=XXXXX`
3. The **OS intercepts this URL** and routes it to your registered app
4. Your app's URL scheme handler receives it and extracts the code

**When it works**:
- ✅ When the URL scheme is **registered in the OS** (Info.plist on iOS, AndroidManifest.xml on Android)
- ✅ When you're opening the auth URL **from the same device** running the app
- ✅ **Native mobile apps** (iOS/Android)

**When it FAILS**:
- ❌ When testing from **desktop/browser** (your test script was running on macOS, not iOS)
- ❌ The macOS system **doesn't know about** `com.wdh.audiobook://` scheme
- ❌ Safari/browser can't route the URL to a non-existent app
- ❌ Baidu redirects to the URL, but nothing catches it

### "oob" (Out-of-Band)
**How it works**:
1. User authorizes on Baidu's page
2. Instead of redirecting, Baidu **displays the authorization code on screen**
3. You **manually copy/paste the code** to your client
4. No URL routing needed

**When it works**:
- ✅ **Desktop testing** (where custom URL schemes don't exist)
- ✅ **CLI/server applications** (no browser control)
- ✅ **Desktop clients** (no app registration possible)
- ✅ **Testing & development**

**When it FAILS**:
- ❌ User experience is poor (requires manual code entry)
- ❌ Not suitable for production apps
- ❌ Prone to user error

## Visual Comparison

```
CUSTOM URL SCHEME (com.wdh.audiobook://oauth-callback)
═════════════════════════════════════════════════════════

User App (iOS)
      ↓
[Open Safari with auth URL]
      ↓
Baidu Auth Server
      ↓
[User clicks "Approve"]
      ↓
Baidu redirects to: com.wdh.audiobook://oauth-callback?code=XXX
      ↓
iOS OS intercepts URL
      ↓
Routes to Your App (because scheme is registered in Info.plist)
      ↓
Your App receives code → Exchanges for token → Success ✅


"oob" (Out-of-Band)
═════════════════════════════════════════════════════════

Your Desktop/CLI Script (Python)
      ↓
[Opens browser with auth URL]
      ↓
Baidu Auth Server
      ↓
[User clicks "Approve"]
      ↓
Baidu displays code on screen:
"Authorization Code: 4/0xxxxx"
      ↓
You manually copy the code
      ↓
Paste into prompt: "Enter code: 4/0xxxxx"
      ↓
Script exchanges for token → Success ✅
```

## Why You Got `redirect_uri_mismatch` Error

You were testing from **macOS desktop** with the test script, but the redirect URI was set to a **mobile app scheme** that only works when the app is actually installed and registered.

### What Happened:
1. You set redirect URI to: `com.wdh.audiobook://oauth-callback`
2. Baidu checked console config: ✅ Matches
3. You opened auth URL in macOS browser
4. User authorized
5. Baidu tried to redirect to: `com.wdh.audiobook://oauth-callback?code=XXX`
6. macOS Safari: "I don't know how to handle `com.wdh.audiobook://` scheme"
7. **Browser error** or **URL doesn't resolve**
8. Actually, the real issue: The initial request showed `redirect_uri_mismatch` because:
   - Console had one config
   - Your request parameter had a different format
   - They didn't match character-for-character

## Why "oob" Worked

"oob" doesn't require any URL routing. Baidu just displays the code on the page. No special handling needed on any platform.

## For Your iOS App: Both Will Work!

### In Production (Your iOS App):
- **Use**: `com.wdh.audiobook://oauth-callback`
- Register the scheme in **Info.plist**
- Use `ASWebAuthenticationSession` to handle the callback
- When iOS receives the scheme URL, your app gets the code
- ✅ Seamless native UX

### For Testing (Desktop):
- **Use**: `oob`
- No URL scheme registration needed
- Manual code entry is fine for testing
- Easier to debug
- ✅ Works from any desktop

## Best Practice for Development

```swift
// iOS App (Production)
#if targetEnvironment(simulator)
    // For simulator testing, you could use:
    // - localhost redirect URI with local server
    // - oob with manual entry
    let redirectURI = "oob"  // or "http://localhost:8080/callback"
#else
    // For real device
    let redirectURI = "com.wdh.audiobook://oauth-callback"
#endif
```

Or better: **Just use the custom scheme** - it works on both simulator and device as long as the app is built and installed on that device.

## Summary

| Scenario | Redirect URI | Why |
|----------|--------------|-----|
| iOS App (real device) | `com.wdh.audiobook://oauth-callback` | URL scheme registered in app |
| iOS Simulator | `com.wdh.audiobook://oauth-callback` | Works if app is running |
| macOS Desktop (testing) | `oob` | No app to register scheme |
| Desktop Web App | `http://localhost:8080/callback` | Control local server |
| Server/Backend | `urn:ietf:wg:oauth:2.0:oob` | No browser capability |

## Action Items for Your App

1. ✅ Keep console config as: `com.wdh.audiobook://oauth-callback`
2. ✅ Register scheme in **Info.plist** under `CFBundleURLTypes`
3. ✅ Implement URL scheme handler in **SceneDelegate** or **AppDelegate**
4. ✅ Use `ASWebAuthenticationSession` with matching scheme
5. ✅ Test on iOS Simulator (has app registered)
6. ✅ For desktop testing during development: switch to `oob` temporarily

This is the standard pattern used by all mobile OAuth apps!
