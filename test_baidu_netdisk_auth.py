#!/usr/bin/env python3
"""
Baidu Netdisk OAuth 2.0 Authorization Test Script (Native/Mobile App)
This script helps you test the OAuth flow for apps using custom URL schemes.
"""

import urllib.parse
import webbrowser
import requests
import json

# Your Baidu App Credentials
APP_KEY = "37MPKvV2gjL7SKHTwoErDDlOEWCO9Pi4"
SECRET_KEY = "cUTK7dZv9HCTCuNuD362xGZqueyGmwPD"
SIGN_KEY = "b9s=TW3*3LY=zyEUp#YZ3Lacxc#^M8be"

# OAuth Configuration
# Note: Use "oob" for out-of-band (manual code entry) if custom URL schemes don't work
REDIRECT_URI = "oob"  # Try this first
# REDIRECT_URI = "com.wdh.audiobook://oauth-callback"  # Original - might not be supported
AUTHORIZATION_URL = "https://openapi.baidu.com/oauth/2.0/authorize"
TOKEN_URL = "https://openapi.baidu.com/oauth/2.0/token"
FILE_LIST_URL = "https://pan.baidu.com/rest/2.0/xpan/file"


def step1_get_authorization_url():
    """Step 1: Generate authorization URL"""
    print("=" * 60)
    print("STEP 1: Generating Authorization URL")
    print("=" * 60)

    # Build authorization URL
    params = {
        'response_type': 'code',
        'client_id': APP_KEY,
        'redirect_uri': REDIRECT_URI,
        'scope': 'basic,netdisk',  # Request basic info and netdisk access
        'display': 'mobile'  # Use mobile display for custom URL schemes
    }

    auth_url = f"{AUTHORIZATION_URL}?{urllib.parse.urlencode(params)}"

    print(f"\n✓ Authorization URL generated:\n")
    print(auth_url)
    print("\n" + "=" * 60)
    print("INSTRUCTIONS:")
    print("=" * 60)
    print("1. Copy the URL above")
    print("2. Open it in a browser (or use the browser in your app)")
    print("3. Complete the authorization")
    print("4. After authorization, you'll be redirected to:")
    print(f"   {REDIRECT_URI}?code=AUTHORIZATION_CODE")
    print("5. Copy the authorization code from the redirect URL")
    print("=" * 60)

    # Optionally open the URL in browser
    open_browser = input("\nDo you want to open this URL in your browser now? (y/n): ").lower()
    if open_browser == 'y':
        webbrowser.open(auth_url)
        print("\n✓ Browser opened. Complete the authorization process.")

    return auth_url


def step2_exchange_token(code):
    """Step 2: Exchange authorization code for access token"""
    print("\n" + "=" * 60)
    print("STEP 2: Exchanging Code for Access Token")
    print("=" * 60)

    params = {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': APP_KEY,
        'client_secret': SECRET_KEY,
        'redirect_uri': REDIRECT_URI
    }

    print(f"\nRequesting token from: {TOKEN_URL}")
    print(f"Code: {code[:20]}...")

    response = requests.get(TOKEN_URL, params=params)

    if response.status_code == 200:
        token_data = response.json()

        # Check for error in response
        if 'error' in token_data:
            print(f"\n✗ Error in token response:")
            print(f"   Error: {token_data.get('error')}")
            print(f"   Description: {token_data.get('error_description', 'N/A')}")
            return None

        print("\n✓ Token received successfully!")
        print(f"\nToken Data:")
        print(json.dumps(token_data, indent=2))
        return token_data
    else:
        print(f"\n✗ HTTP Error: {response.status_code}")
        print(f"Response: {response.text}")
        return None


def step3_get_file_list(access_token):
    """Step 3: Get user's file list"""
    print("\n" + "=" * 60)
    print("STEP 3: Fetching File List")
    print("=" * 60)

    params = {
        'access_token': access_token,
        'method': 'list',
        'dir': '/',  # Root directory
    }

    print(f"\nRequesting file list from: {FILE_LIST_URL}")
    response = requests.get(FILE_LIST_URL, params=params)

    if response.status_code == 200:
        file_data = response.json()

        # Check for error in response
        if 'errno' in file_data and file_data['errno'] != 0:
            print(f"\n✗ API Error:")
            print(f"   Error code: {file_data.get('errno')}")
            print(f"   Error message: {file_data.get('errmsg', 'N/A')}")
            return None

        print("\n✓ File list received successfully!")
        print(f"\nFile List Data:")
        print(json.dumps(file_data, indent=2, ensure_ascii=False))
        return file_data
    else:
        print(f"\n✗ HTTP Error: {response.status_code}")
        print(f"Response: {response.text}")
        return None


def test_with_manual_code():
    """Manual testing flow - user provides the authorization code"""
    print("\n" + "=" * 60)
    print("Baidu Netdisk OAuth 2.0 Authorization Test")
    print("(Custom URL Scheme Mode)")
    print("=" * 60)

    # Step 1: Generate and display authorization URL
    auth_url = step1_get_authorization_url()

    # Step 2: Get authorization code from user
    print("\n" + "=" * 60)
    print("After completing authorization, paste the code here:")
    print("=" * 60)
    code = input("\nAuthorization code: ").strip()

    if not code:
        print("\n✗ No authorization code provided")
        return

    # Step 3: Exchange for access token
    token_data = step2_exchange_token(code)

    if not token_data or 'access_token' not in token_data:
        print("\n✗ Failed to get access token")
        return

    access_token = token_data['access_token']

    # Step 4: Test file list API
    print("\n" + "=" * 60)
    print("Would you like to test the file list API?")
    print("=" * 60)
    test_api = input("Test file list API? (y/n): ").lower()

    if test_api == 'y':
        file_data = step3_get_file_list(access_token)

        if file_data:
            print("\n" + "=" * 60)
            print("SUCCESS! All tests passed!")
            print("=" * 60)
            print("\nToken Information:")
            print(f"  Access Token: {access_token[:30]}...")
            print(f"  Expires in: {token_data.get('expires_in', 'unknown')} seconds (~{token_data.get('expires_in', 0)//86400} days)")
            if 'refresh_token' in token_data:
                print(f"  Refresh Token: {token_data['refresh_token'][:30]}...")
        else:
            print("\n✗ Failed to get file list, but token exchange was successful")
            print(f"\nAccess Token: {access_token[:30]}...")
    else:
        print("\n" + "=" * 60)
        print("Token Exchange Successful!")
        print("=" * 60)
        print(f"\nAccess Token: {access_token[:30]}...")
        print(f"Expires in: {token_data.get('expires_in', 'unknown')} seconds")


def test_with_existing_token():
    """Test with an existing access token"""
    print("\n" + "=" * 60)
    print("Test with Existing Access Token")
    print("=" * 60)

    access_token = input("\nEnter your access token: ").strip()

    if not access_token:
        print("\n✗ No access token provided")
        return

    file_data = step3_get_file_list(access_token)

    if file_data:
        print("\n✓ Access token is valid and working!")
    else:
        print("\n✗ Access token test failed")


def main():
    """Main entry point"""
    print("\n" + "=" * 70)
    print("Baidu Netdisk OAuth 2.0 Test Tool")
    print("=" * 70)
    print("\nIMPORTANT: Make sure you have configured the redirect URI:")
    print(f"  {REDIRECT_URI}")
    print("in your Baidu Developer Console before proceeding.")
    print("\n" + "=" * 70)
    print("Select test mode:")
    print("=" * 70)
    print("1. Complete OAuth flow (get new authorization)")
    print("2. Test existing access token")
    print("=" * 70)

    choice = input("\nEnter choice (1 or 2): ").strip()

    if choice == '1':
        test_with_manual_code()
    elif choice == '2':
        test_with_existing_token()
    else:
        print("\n✗ Invalid choice")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nTest cancelled by user")
    except Exception as e:
        print(f"\n\n✗ Error: {e}")
        import traceback
        traceback.print_exc()
