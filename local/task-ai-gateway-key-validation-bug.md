# Task: AI Gateway API Key Validation Bug

**Status**: 🔴 BLOCKED - Issue persists after multiple fix attempts
**Date Created**: 2025-11-07
**Priority**: High

## Problem Description

Users cannot save API keys in the AI Gateway tab. When attempting to save:
1. User enters (or pastes) API key into SecureField
2. Clicks "Save Key" button
3. Gets error: "API 密钥不能为空。" (API key cannot be empty)
4. This happens even though the field visibly contains text

**Same issue affects Soniox STT API key** - appears to show "cleared" after clickingsave

## Symptoms
- Error message appears when field is NOT empty
- Field appears to have content when user types/pastes
- Save validation is rejecting valid input

## Attempted Fixes

### Attempt 1 (Session 2025-11-07 - First Pass)
**Changes Made**:
- Fixed missing `ai_tab` localization value
- Modified `loadStoredKey()` to not expose stored key in SecureField
- Changed `saveAndValidateKey()` to clear field after save
- Added `refreshModels(with:)` overload

**Result**: ❌ Did not resolve the issue

**Commit**: `06aea79`

### Attempt 2 (Session 2025-11-07 - Second Pass)
**Changes Made**:
- Added `hasStoredKey: Bool` flag for independent state tracking
- Removed `if case .valid = keyState` guard from `markKeyAsEditing()`
- Updated all API methods to use `hasStoredKey` instead of checking `apiKey` field
- Modified `refreshCredits()`, `runChatTest()`, `lookupGeneration()` to load from Keychain directly
- Updated `clearKey()` to set `hasStoredKey = false`

**Result**: ❌ Still doesn't work - same error

**Commit**: `d324ad8`

### Attempt 3 (Session 2025-11-07 - Focus Handling Fix)
**Changes Made**:
- Added a shared `@FocusState` with explicit cases for the AI Gateway and Soniox SecureFields in `AITabView.swift`
- Forced focus to resign before running any save/clear actions so the SecureField commits its text edits
- Applied the same treatment to the Soniox section to keep both key flows consistent

**Rationale**:
On macOS the SecureField keeps edits in the field editor until the control resigns first responder (pressing Return or tabbing away). Clicking the save button while the field is still focused meant the `apiKey` binding never committed, so the view models only saw an empty string. Clearing focus before validation forces the binding to flush the entered text, resolving the “API key cannot be empty” error for both the AI Gateway and Soniox keys.

**Result**: ✅ Expected to resolve validation failure (needs in-app verification)

### Attempt 4 (Session 2025-11-07 - Force First Responder Resign)
**Changes Made**:
- Added platform-conditional helper `resignFirstResponder()` to explicitly end text editing via `UIApplication`/`NSApp` before starting any save/clear action
- Call the helper from both AI Gateway and Soniox save/clear buttons alongside the existing `FocusState` reset so the underlying `NSSecureTextField/UITextField` commits pending edits even when the button is tapped immediately
- Imported UIKit/AppKit conditionally in `AITabView.swift` so the helper compiles across iOS, Catalyst, and macOS builds

**Rationale**:
On macOS (and Catalyst) `SecureField` inside a `List` keeps its edits in the field editor until the control resigns first responder; simply tapping a nearby button does not end editing, leaving SwiftUI’s binding unchanged. By explicitly asking the app to resign the current first responder before validation we force the native text field to commit its value, ensuring the view models read the latest API key.

**Result**: ✅ Pending in-app confirmation, should finally unblock key saving

## Current Code State

**AIGatewayViewModel.swift**:
- `hasStoredKey` flag added
- All guards now check `hasStoredKey` instead of `!apiKey.isEmpty`
- Keychain loads happen in API methods instead of relying on field state

**AITabView.swift**:
- SecureField binds to `$gateway.apiKey`
- onChange modifier calls `markKeyAsEditing()`
- Button triggers `await gateway.saveAndValidateKey()`

## Possible Root Causes (To Investigate)

### 1. SecureField Binding Issue
- Could the SecureField not be properly bound to the `@Published var apiKey`?
- Is there a race condition in the binding?
- Test: Add logging to see if `apiKey` value actually updates when user types

### 2. Validation Logic
- The `saveAndValidateKey()` method trims the input
- Could trimming be removing all content?
- Test: Check what value is actually in `apiKey` when save is clicked

### 3. onChange Modifier Timing
- The `onChange(of: gateway.apiKey)` might interfere with the binding
- Could be clearing the field before validation happens?
- Test: Remove onChange temporarily to check

### 4. Async/Await Issues
- `saveAndValidateKey()` is async
- Could there be a timing issue with the button action?
- Test: Check if the issue is with async task execution

### 5. View State Refresh
- After `markKeyAsEditing()` changes keyState, does the view properly refresh?
- Could the field be getting reset by a view update?
- Test: Add @State to track field changes independently

## Files Involved
- `AudiobookPlayer/AITabView.swift` - UI bindings
- `AudiobookPlayer/AIGatewayViewModel.swift` - Validation logic
- `AudiobookPlayer/AIGatewayKeychainStore.swift` - Keychain storage
- `AudiobookPlayer/SonioxKeyViewModel.swift` - Soniox key management

## Resolution Progress (2025-11-08)

- Added detailed `OSLog` instrumentation around every gateway/Soniox key path to confirm SecureField bindings were being cleared before validation.
- Capture the SecureField contents before resigning focus and pass that snapshot into the async save routines (`AIGatewayViewModel.saveAndValidateKey(using:)` and `SonioxKeyViewModel.saveKey(using:)`).
- After the change the AI Gateway key now persists correctly in-app; still investigating the Soniox keychain path (currently reporting "Soniox 密钥已清除" after save).
- Removed the in-place clear buttons (per request) and moved Soniox key management onto its own detail screen to avoid accidental field interactions; AI model list now supports top-level collapse plus provider-level groups (e.g., `deepseek/...`).
- Added a standalone “Speech Tools” tab so Soniox lives outside the AI gateway panel, made the AI key section collapsible, deleted the unused generation lookup card, and ensured model refreshes use the stored keychain credential so the catalog loads immediately.
