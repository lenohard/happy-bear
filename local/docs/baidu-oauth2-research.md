# Baidu OAuth2 Authentication Research

**Date**: 2025-11-02 (Updated: 2025-11-02)
**Status**: ✅ Tested & Verified
**Related**: iOS app integration with Baidu Pan (cloud storage)

## Overview

Baidu OAuth2 is used to enable iOS apps to access users' Baidu Pan (Baidu's cloud storage service) with user consent. After OAuth2 authorization, the app receives an access token that allows it to interact with Baidu Pan APIs to list, read, and download files.

**Test Status**: ✅ Successfully tested complete OAuth2 flow with custom URL scheme redirect URI (`com.wdh.audiobook://oauth-callback`).

## Use Case

1. User opens iOS app
2. App initiates Baidu OAuth2 authorization flow
3. User approves permission for app to access Baidu Pan
4. App receives OAuth2 access token
5. App uses access token to:
   - List files in user's Baidu Pan
   - Read file metadata
   - Download files
   - (Potentially upload files, depending on permissions)

## Key Endpoints

### Authorization Endpoint (User Consent)
```
GET https://openapi.baidu.com/oauth/2.0/authorize
```

**Purpose**: Redirect users here to request authorization

**Required Parameters**:
- `response_type`: Always `code` for authorization code flow
- `client_id`: Your AppKey from Baidu Developer Console
- `redirect_uri`: Must exactly match the URI configured in console
- `scope`: Comma-separated permissions (e.g., `basic,netdisk`)

**Optional Parameters**:
- `display`: Display mode - `page`, `popup`, `dialog`, `mobile`
- `state`: CSRF protection token (recommended)
- `force_login`: `1` to force re-login, `0` for SSO

**Example**:
```
https://openapi.baidu.com/oauth/2.0/authorize?response_type=code&client_id=37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4&redirect_uri=com.wdh.audiobook://oauth-callback&scope=basic,netdisk&display=mobile
```

### Token Endpoint (Code Exchange)
```
GET https://openapi.baidu.com/oauth/2.0/token
```

**Purpose**: Exchange authorization code for access token

**Required Parameters**:
- `grant_type`: `authorization_code` for initial token, `refresh_token` for refresh
- `code`: Authorization code from authorization endpoint (for authorization_code grant)
- `client_id`: Your AppKey
- `client_secret`: Your SecretKey
- `redirect_uri`: Must match the one used in authorization request

**Example**:
```bash
curl "https://openapi.baidu.com/oauth/2.0/token?grant_type=authorization_code&code=AUTHORIZATION_CODE&client_id=37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4&client_secret=cUTK7dZv9HCTCuNuD362xGZqueyGmwPD&redirect_uri=com.wdh.audiobook://oauth-callback"
```

**Response**:
```json
{
  "access_token": "121.xxx",
  "expires_in": 2592000,
  "refresh_token": "122.xxx",
  "scope": "basic netdisk",
  "session_key": "xxx",
  "session_secret": "xxx"
}
```

### File List API
```
GET https://pan.baidu.com/rest/2.0/xpan/file
```

**Purpose**: List files in user's Baidu Pan directory

**Required Parameters**:
- `access_token`: Your access token
- `method`: `list` (fixed)
- `dir`: Directory path (e.g., `/`)

**Optional Parameters**:
- `folder`: `0` = all files, `1` = folders only
- `start`: Start index for pagination (default: 0)
- `limit`: Number of results (default: 1000, max: 10000)

**Example**:
```bash
curl "https://pan.baidu.com/rest/2.0/xpan/file?method=list&access_token=YOUR_ACCESS_TOKEN&dir=/"
```

## OAuth2 Parameters

### Baidu App Credentials (from Developer Console)
- **AppKey** - Application identifier, used as `client_id` in OAuth2 requests
- **SecretKey** - Used as `client_secret` in OAuth2 requests
- **SignKey** - Used for certain API validations (less common in OAuth2 flow)
- **Redirect URI** - Where users will be redirected after authorization (must be configured in console)

### Token Endpoint Parameters
```
client_id       # Your AppKey
client_secret   # Your SecretKey
grant_type      # authorization_code OR refresh_token
code            # Authorization code (for authorization_code grant)
refresh_token   # Refresh token (for refresh_token grant)
redirect_uri    # Registered redirect URI - MUST MATCH CONSOLE CONFIGURATION
```

## Access Token Details

- **Validity Period**: 30 days (2,592,000 seconds)
- **Usage**: Included in API requests as `access_token` parameter
- **Format**: String token carrying identity and permission information
- **Refresh**: Supported via `refresh_token` with `grant_type=refresh_token`
- **Single-use Refresh Token**: Each refresh generates a new `refresh_token` for next use

## Supported Grant Types

1. **authorization_code** - User-based authentication with consent (OAuth2 authorization code flow)
   - User authorizes app to access their Baidu Pan
   - App receives authorization code
   - App exchanges code for access token
   - ✅ VERIFIED WORKING with custom URL scheme

2. **refresh_token** - Refresh expired access tokens
   - Use existing `refresh_token` to get new `access_token`
   - Generates new `refresh_token` for future refreshes

## Authorization Flow (Tested & Working)

### Step 1: Open Authorization URL in Browser/WebView
```
https://openapi.baidu.com/oauth/2.0/authorize?response_type=code&client_id=37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4&redirect_uri=com.wdh.audiobook://oauth-callback&scope=basic,netdisk&display=mobile
```

In iOS, use `ASWebAuthenticationSession` or `SFSafariViewController`:
```swift
let authURL = URL(string: "https://openapi.baidu.com/oauth/2.0/authorize?response_type=code&client_id=YOUR_APPKEY&redirect_uri=com.wdh.audiobook://oauth-callback&scope=basic,netdisk&display=mobile")!

let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "com.wdh.audiobook") { callbackURL, error in
    // Handle callback
}
session.presentationContextProvider = self
session.start()
```

### Step 2: User Authorizes
- User sees Baidu login/permission screen
- User approves access to Baidu Pan
- Baidu redirects to: `com.wdh.audiobook://oauth-callback?code=XXXXX`

### Step 3: Extract Authorization Code
- Your app's custom URL scheme handler receives the callback
- Extract `code` parameter from the redirect URL

### Step 4: Exchange Code for Token
```bash
curl "https://openapi.baidu.com/oauth/2.0/token?grant_type=authorization_code&code=XXXXX&client_id=37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4&client_secret=cUTK7dZv9HCTCuNuD362xGZqueyGmwPD&redirect_uri=com.wdh.audiobook://oauth-callback"
```

### Step 5: Use Access Token
```bash
curl "https://pan.baidu.com/rest/2.0/xpan/file?method=list&access_token=YOUR_ACCESS_TOKEN&dir=/"
```

### Step 6: Handle Token Refresh (Every 30 Days)
```bash
curl "https://openapi.baidu.com/oauth/2.0/token?grant_type=refresh_token&refresh_token=YOUR_REFRESH_TOKEN&client_id=37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4&client_secret=cUTK7dZv9HCTCuNuD362xGZqueyGmwPD"
```

**Important**: Store the new `refresh_token` from response for next refresh.

## Important Considerations

### Redirect URI Configuration (CRITICAL)
- ✅ **Custom URL schemes ARE supported** by Baidu Netdisk Open Platform
- Redirect URI must **exactly match** what's configured in Baidu Developer Console
- Common format for native apps: `com.appname://oauth-callback` or `myapp://callback`
- **Character-by-character match required** - even trailing slashes matter
- Configuration location: https://pan.baidu.com/union/console/application
- **Lesson Learned**: Initial error "redirect_uri_mismatch" was resolved by verifying exact match between console config and request parameter

### Custom URL Scheme vs "oob" - When to Use Each

#### Custom URL Scheme (`com.wdh.audiobook://oauth-callback`)

**How it works**:
1. User authorizes on Baidu's page
2. Baidu redirects to: `com.wdh.audiobook://oauth-callback?code=XXXXX`
3. The OS intercepts this URL and routes it to your registered app
4. Your app's URL scheme handler receives it and extracts the code

**When it works**:
- ✅ **Production iOS/Android apps** where the scheme is registered in the OS
- ✅ **iOS Simulator** (when app is built and running)
- ✅ **Native mobile apps** with registered URL schemes

**When it FAILS**:
- ❌ **Desktop testing** (macOS Safari doesn't know about `com.wdh.audiobook://` scheme)
- ❌ Testing from a platform where the app is not installed
- ❌ No URL scheme registration in the OS

#### "oob" (Out-of-Band) Mode

**How it works**:
1. User authorizes on Baidu's page
2. Instead of redirecting, Baidu **displays the authorization code on screen**
3. You **manually copy/paste the code** to your client
4. No URL routing or app registration needed

**When it works**:
- ✅ **Desktop testing** (no scheme registration needed)
- ✅ **CLI/server applications** (no browser control)
- ✅ **Testing & development** on any platform
- ✅ **When custom scheme is unavailable**

**When to use**:
- ❌ **Not suitable for production** (poor user experience)
- ✅ **Perfect for development & testing**

#### Comparison Table

| Scenario | Redirect URI | Why |
|----------|--------------|-----|
| iOS App (production) | `com.wdh.audiobook://oauth-callback` | Scheme registered in app's Info.plist |
| iOS Simulator | `com.wdh.audiobook://oauth-callback` | Works if app is built and running |
| macOS Desktop (testing) | `oob` | No app to register scheme; manual code entry |
| Desktop testing backup | `http://localhost:8080/callback` | Alternative: run local HTTP server |
| Server/Backend | `urn:ietf:wg:oauth:2.0:oob` | Standard OOB format for non-browser apps |

#### Development Strategy

```swift
// iOS App Configuration
#if DEBUG
    // For testing during development, you can conditionally use:
    // Option 1: Keep custom scheme (works on simulator if app is running)
    let redirectURI = "com.wdh.audiobook://oauth-callback"

    // Option 2: Use oob for desktop testing (manual code entry)
    // let redirectURI = "oob"
#else
    // Production: always use custom scheme
    let redirectURI = "com.wdh.audiobook://oauth-callback"
#endif
```

**Recommended approach**: Use custom scheme everywhere - it works on both simulator and device as long as the app is built and installed. Only switch to `oob` if testing from a platform where the app cannot be installed.

### Scope & Permissions
- `basic` - Basic user information access
- `netdisk` - Baidu Pan/Netdisk file access
- Scopes are specified as comma-separated: `basic,netdisk`
- User sees permission dialog requesting these scopes during authorization
- Request specific scopes user will see in authorization dialog

### Token Management
- Access tokens expire after 30 days (2,592,000 seconds)
- Must implement refresh token flow for long-lived access
- Use `grant_type=refresh_token` with existing `refresh_token` to get new token
- **Important**: Each refresh generates a new `refresh_token` - store the new one immediately
- Securely store tokens on iOS device using **Keychain** (NOT UserDefaults)

### Authorization Code Lifespan
- Authorization code valid for **10 minutes**
- Code is **single-use** only
- Code automatically expires after 10 minutes of inactivity
- Must exchange code within 10-minute window

### API Availability
- ✅ **File listing API verified**: `https://pan.baidu.com/rest/2.0/xpan/file`
- File metadata accessible
- Download supported via file APIs
- Upload supported (scope permitting)
- Rate limiting may apply on API calls

## Implementation Checklist for iOS App

- [ ] Register custom URL scheme `com.wdh.audiobook://oauth-callback` in Info.plist under `CFBundleURLTypes`
- [ ] Implement AppDelegate or SceneDelegate method to handle URL callbacks:
  ```swift
  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
      // Handle the OAuth callback here
  }
  ```
- [ ] Use `ASWebAuthenticationSession` for authorization (iOS 12+) or `SFSafariViewController`
- [ ] Implement secure token exchange API call using URLSession
- [ ] Store `access_token` and `refresh_token` in Keychain (use Security framework)
- [ ] Implement token refresh logic before expiration (check expires_in field)
- [ ] Implement file list API calls to fetch user's files
- [ ] Handle token expiration gracefully (refresh or re-authorize)
- [ ] Test complete OAuth2 flow end-to-end
- [ ] Implement error handling for authorization failures
- [ ] Securely handle API errors and token errors
- [ ] Consider using a library like `KeychainAccess` for simpler Keychain management

## Testing

A test script has been created at: `/Users/senaca/test_baidu_netdisk_auth.py`

**Features**:
- Mode 1: Complete OAuth flow with manual code entry
- Mode 2: Test existing access token validity
- Tests file list API after successful authorization
- Provides detailed error messages for troubleshooting

**Usage**:
```bash
python3 /Users/senaca/test_baidu_netdisk_auth.py
```

**Test Results (2025-11-02)**:
- ✅ Custom URL scheme redirect URI supported
- ✅ Authorization endpoint accepts requests
- ✅ Token exchange successful
- ✅ File list API returns user's files
- ✅ Complete flow verified end-to-end

## Next Steps

1. ✅ Verify API Availability - Confirmed Baidu Pan exposes OAuth2-accessible APIs
2. ✅ Research Authorization Endpoint - `https://openapi.baidu.com/oauth/2.0/authorize`
3. ✅ Check Scopes - Documented available scopes (`basic`, `netdisk`)
4. ✅ Test OAuth2 Flow - Complete flow tested and verified with custom URL scheme
5. **Implement iOS Integration** - Use ASWebAuthenticationSession with proper URL scheme handling
6. **Token Storage** - Implement secure Keychain storage for tokens
7. **Refresh Logic** - Implement token refresh before expiration (30-day window)
8. **Error Handling** - Robust error handling for auth failures, token expiration, API errors

## References

- **Baidu Netdisk Open Platform**: https://pan.baidu.com/union/
- **Authorization Documentation**: https://pan.baidu.com/union/doc/ol0rsap9s
- **Access Token Guide**: https://pan.baidu.com/union/doc/al0rwqzzl (Authorization Code Mode)
- **File List API**: https://pan.baidu.com/union/doc/nksg0sat3
- **Official Baidu Developer Platform**: https://developer.baidu.com/
- **OAuth2 Specification**: RFC 6749 - The OAuth 2.0 Authorization Framework

## Research Progress

- [x] Identified authorization endpoint: `https://openapi.baidu.com/oauth/2.0/authorize`
- [x] Identified token endpoint: `https://openapi.baidu.com/oauth/2.0/token`
- [x] Documented required OAuth2 credentials and parameters
- [x] Clarified use case: iOS app accessing user's Baidu Pan files
- [x] **Verified custom URL scheme support** for redirect_uri (SOLVED redirect_uri_mismatch error)
- [x] Document OAuth2 scopes (`basic`, `netdisk`) required for Netdisk access
- [x] **Tested complete authorization code flow end-to-end**
- [x] Verified file list API works with access tokens
- [x] Documented token lifespan (30 days) and refresh mechanism
- [x] Created Python test script for OAuth2 flow validation
- [x] Built iOS prototype with ASWebAuthenticationSession and token exchange (xcodebuild simulator build succeeded 2025-11-02)

## Implementation Notes (2025-11-02)

### Credentials Used for Testing
- **AppKey**: `37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4`
- **SecretKey**: `cUTK7dZv9HCTCuNuD362xGZqueyGmwPD`
- **Redirect URI**: `com.wdh.audiobook://oauth-callback` ✅ VERIFIED WORKING

### iOS App Integration
- Added `BaiduOAuthService` and `BaiduAuthViewModel` in the SwiftUI app to drive the Authorization Code flow using `ASWebAuthenticationSession`.
- Info.plist now declares placeholder credentials (`BaiduClientId`, `BaiduClientSecret`, `BaiduRedirectURI`, `BaiduScope`) and registers the custom scheme `com.wdh.audiobook://` so the OAuth redirect can return control to the app.
- SwiftUI `ContentView` exposes a Baidu sign-in section showing token expiry, scopes, and failure states; playback controls remain available for local testing.
- Build verified with `xcodebuild -project AudiobookPlayer.xcodeproj -scheme AudiobookPlayer -destination 'generic/platform=iOS Simulator' build`.

## Key Learnings & Best Practices

1. **Custom URL Schemes Work for Native Apps**: Baidu Netdisk Open Platform fully supports custom URL scheme redirect URIs for iOS/Android native apps. This is the standard approach for mobile OAuth.

2. **Exact Matching Required**: Redirect URI must match character-for-character in both:
   - Baidu Developer Console configuration
   - Authorization request parameter
   - Token exchange request parameter
   - Any mismatch will result in `redirect_uri_mismatch` error

3. **Token Lifespan & Refresh Strategy**:
   - Access tokens valid for 30 days
   - Can be refreshed multiple times using refresh_token
   - Each refresh generates a new refresh_token (single-use design)
   - Must store new refresh_token immediately after each refresh

4. **Authorization Code Expiration**:
   - Code valid for only 10 minutes
   - Single-use only
   - Must implement immediate token exchange after user authorizes

5. **Complete File API Exists**: File listing, metadata, and download operations fully supported via `https://pan.baidu.com/rest/2.0/xpan/file` REST API.

6. **Mobile Display Mode Recommended**: Use `display=mobile` parameter when opening authorization in mobile WebView for better UX.

7. **Keychain Storage Essential**: Always store sensitive tokens in iOS Keychain, not UserDefaults or other insecure storage.

8. **ASWebAuthenticationSession Benefits**:
   - Native system browser integration (better security)
   - Automatic URL scheme handling
   - Built-in error handling
   - Recommended over SFSafariViewController for OAuth flows (iOS 12+)
