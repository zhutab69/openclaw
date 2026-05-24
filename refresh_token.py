"""Manually refresh Kiro auth token using AWS SSO OIDC."""
import json, urllib.request, os

CREDS_FILE = r"C:\Users\zhuyulin\.aws\sso\cache\kiro-auth-token.json"
CLIENT_FILE = r"C:\Users\zhuyulin\.aws\sso\cache\58fbcb9a0e52bd94d951203bea6aceebbf330175.json"

# Load current credentials
with open(CREDS_FILE, "r") as f:
    creds = json.load(f)

with open(CLIENT_FILE, "r") as f:
    client = json.load(f)

print(f"Current token expires: {creds['expiresAt']}")
print(f"Client ID: {client['clientId'][:20]}...")
print(f"Region: {creds.get('region', 'us-east-1')}")

# Call AWS SSO OIDC token endpoint to refresh
region = creds.get("region", "us-east-1")
url = f"https://oidc.{region}.amazonaws.com/token"

payload = json.dumps({
    "clientId": client["clientId"],
    "clientSecret": client["clientSecret"],
    "grantType": "refresh_token",
    "refreshToken": creds["refreshToken"]
}).encode()

req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})

try:
    resp = urllib.request.urlopen(req, timeout=15)
    data = json.loads(resp.read())
    print(f"\nRefresh SUCCESS!")
    print(f"New expiresIn: {data.get('expiresIn')}s")
    
    # Update creds file
    creds["accessToken"] = data["accessToken"]
    if "refreshToken" in data:
        creds["refreshToken"] = data["refreshToken"]
    
    # Calculate new expiry
    from datetime import datetime, timezone, timedelta
    expires = datetime.now(timezone.utc) + timedelta(seconds=data["expiresIn"])
    creds["expiresAt"] = expires.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    
    with open(CREDS_FILE, "w") as f:
        json.dump(creds, f, indent=2)
    
    print(f"New expiresAt: {creds['expiresAt']}")
    print("Token file updated!")
    
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"\nRefresh FAILED: {e.code}")
    print(f"Response: {body[:300]}")
    
    # If refresh token is revoked (invalid_grant), prompt re-login
    if e.code == 400 and "invalid_grant" in body:
        print("\n" + "=" * 50)
        print("Refresh token revoked (re-login detected).")
        print("Opening Kiro SSO login page...")
        print("After login, restart OpenClaw.")
        print("=" * 50)
        import webbrowser
        webbrowser.open("https://d-90660bc4c1.awsapps.com/start")
        
except Exception as e:
    print(f"\nRefresh ERROR: {e}")
