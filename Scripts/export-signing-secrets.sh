#!/bin/bash
#
# Export signing secrets for GitHub Actions
# Run this script on your Mac to generate all required secrets
#

set -e

echo "=============================================="
echo "  Axii - GitHub Actions Signing Setup"
echo "=============================================="
echo ""

OUTPUT_FILE="${1:-signing-secrets.txt}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Temp directory for certificate
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo "This script will help you export the required secrets for GitHub Actions."
echo "Secrets will be saved to: $OUTPUT_FILE"
echo ""

# -----------------------------------------------------------------------------
# 1. TEAM_ID
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[1/5] Team ID${NC}"
echo "-----------------------------------------------"

# Try to get from project
PROJECT_TEAM_ID=$(grep -A1 'DEVELOPMENT_TEAM' Axii/Axii.xcodeproj/project.pbxproj 2>/dev/null | grep -o '[A-Z0-9]\{10\}' | head -1 || true)

if [ -n "$PROJECT_TEAM_ID" ]; then
    echo "Found Team ID in project: $PROJECT_TEAM_ID"
    read -p "Use this Team ID? [Y/n]: " use_project_team
    if [[ "$use_project_team" =~ ^[Nn] ]]; then
        read -p "Enter your Team ID: " TEAM_ID
    else
        TEAM_ID="$PROJECT_TEAM_ID"
    fi
else
    echo "Could not find Team ID in project."
    echo "Find it at: https://developer.apple.com/account#MembershipDetailsCard"
    read -p "Enter your Team ID: " TEAM_ID
fi

echo -e "${GREEN}✓ Team ID: $TEAM_ID${NC}"
echo ""

# -----------------------------------------------------------------------------
# 2. KEYCHAIN_PASSWORD (generate random)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[2/5] Keychain Password${NC}"
echo "-----------------------------------------------"

KEYCHAIN_PASSWORD=$(openssl rand -base64 32)
echo -e "${GREEN}✓ Generated random keychain password${NC}"
echo ""

# -----------------------------------------------------------------------------
# 3. Developer ID Certificate
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[3/5] Developer ID Application Certificate${NC}"
echo "-----------------------------------------------"

echo "Available Developer ID Application certificates:"
echo ""
security find-identity -v -p codesigning | grep "Developer ID Application" || {
    echo -e "${RED}No Developer ID Application certificate found!${NC}"
    echo "You need to create one at: https://developer.apple.com/account/resources/certificates"
    exit 1
}
echo ""

read -p "Enter the certificate name (or part of it) to export: " CERT_NAME

if [ -z "$CERT_NAME" ]; then
    CERT_NAME="Developer ID Application"
fi

# Find the certificate hash
CERT_HASH=$(security find-identity -v -p codesigning | grep "$CERT_NAME" | head -1 | awk '{print $2}')

if [ -z "$CERT_HASH" ]; then
    echo -e "${RED}Certificate not found matching: $CERT_NAME${NC}"
    exit 1
fi

echo "Found certificate: $CERT_HASH"
echo ""

# Export certificate
P12_FILE="$TEMP_DIR/certificate.p12"

echo "You'll be prompted for:"
echo "  1. Your macOS login password (to access keychain)"
echo "  2. A NEW password to protect the exported .p12 file"
echo ""
read -s -p "Enter a password for the .p12 export (P12_PASSWORD): " P12_PASSWORD
echo ""

security export -k ~/Library/Keychains/login.keychain-db -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$P12_FILE" 2>/dev/null || {
    # Try alternative method
    security find-certificate -c "$CERT_NAME" -p > "$TEMP_DIR/cert.pem" 2>/dev/null
    security find-key -c "$CERT_NAME" -p > "$TEMP_DIR/key.pem" 2>/dev/null || true

    if [ -f "$TEMP_DIR/cert.pem" ]; then
        echo ""
        echo -e "${YELLOW}Note: Automatic export may have issues. Trying manual method...${NC}"
        echo ""
        echo "Please manually export your certificate:"
        echo "  1. Open Keychain Access"
        echo "  2. Find 'Developer ID Application: ...' certificate"
        echo "  3. Right-click → Export..."
        echo "  4. Save as .p12 format"
        echo ""
        read -p "Enter path to exported .p12 file: " MANUAL_P12

        if [ -f "$MANUAL_P12" ]; then
            cp "$MANUAL_P12" "$P12_FILE"
            read -s -p "Enter the password you used for the .p12 export: " P12_PASSWORD
            echo ""
        else
            echo -e "${RED}File not found: $MANUAL_P12${NC}"
            exit 1
        fi
    fi
}

if [ ! -f "$P12_FILE" ] || [ ! -s "$P12_FILE" ]; then
    echo ""
    echo -e "${YELLOW}Automatic export didn't work. Please export manually:${NC}"
    echo ""
    echo "  1. Open Keychain Access"
    echo "  2. Select 'login' keychain and 'My Certificates' category"
    echo "  3. Find 'Developer ID Application: ...' certificate"
    echo "  4. Right-click → Export..."
    echo "  5. Save as .p12 format with a password"
    echo ""
    read -p "Enter path to exported .p12 file: " MANUAL_P12

    if [ -f "$MANUAL_P12" ]; then
        cp "$MANUAL_P12" "$P12_FILE"
        read -s -p "Enter the password you used for the .p12 export: " P12_PASSWORD
        echo ""
    else
        echo -e "${RED}File not found: $MANUAL_P12${NC}"
        exit 1
    fi
fi

# Verify the p12 file
if ! openssl pkcs12 -in "$P12_FILE" -noout -passin "pass:$P12_PASSWORD" 2>/dev/null; then
    echo -e "${RED}Error: Could not verify .p12 file. Password may be incorrect.${NC}"
    exit 1
fi

BUILD_CERTIFICATE_BASE64=$(base64 -i "$P12_FILE")
echo -e "${GREEN}✓ Certificate exported and encoded${NC}"
echo ""

# -----------------------------------------------------------------------------
# 4. Apple ID
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[4/5] Apple ID (for notarization)${NC}"
echo "-----------------------------------------------"

read -p "Enter your Apple ID email: " APPLE_ID
echo -e "${GREEN}✓ Apple ID: $APPLE_ID${NC}"
echo ""

# -----------------------------------------------------------------------------
# 5. App-Specific Password
# -----------------------------------------------------------------------------
echo -e "${YELLOW}[5/5] App-Specific Password${NC}"
echo "-----------------------------------------------"

echo "You need an app-specific password for notarization."
echo ""
echo "To create one:"
echo "  1. Go to https://appleid.apple.com"
echo "  2. Sign in → Sign-In and Security → App-Specific Passwords"
echo "  3. Click '+' to generate a new password"
echo "  4. Name it 'GitHub Actions Notarization'"
echo ""
read -s -p "Paste your app-specific password: " APPLE_APP_PASSWORD
echo ""
echo -e "${GREEN}✓ App-specific password saved${NC}"
echo ""

# -----------------------------------------------------------------------------
# Save all secrets
# -----------------------------------------------------------------------------
echo "=============================================="
echo "  Saving Secrets"
echo "=============================================="
echo ""

cat > "$OUTPUT_FILE" << EOF
# GitHub Actions Secrets for Axii
# Generated on $(date)
#
# Add these as repository secrets at:
# https://github.com/YOUR_ORG/YOUR_REPO/settings/secrets/actions
#
# IMPORTANT: Delete this file after adding secrets to GitHub!

# ============================================
# Secret: TEAM_ID
# ============================================
$TEAM_ID

# ============================================
# Secret: KEYCHAIN_PASSWORD
# ============================================
$KEYCHAIN_PASSWORD

# ============================================
# Secret: P12_PASSWORD
# ============================================
$P12_PASSWORD

# ============================================
# Secret: APPLE_ID
# ============================================
$APPLE_ID

# ============================================
# Secret: APPLE_APP_PASSWORD
# ============================================
$APPLE_APP_PASSWORD

# ============================================
# Secret: BUILD_CERTIFICATE_BASE64
# (This is long - copy the entire value below)
# ============================================
$BUILD_CERTIFICATE_BASE64
EOF

chmod 600 "$OUTPUT_FILE"

echo -e "${GREEN}✓ All secrets saved to: $OUTPUT_FILE${NC}"
echo ""
echo "=============================================="
echo "  Next Steps"
echo "=============================================="
echo ""
echo "1. Open $OUTPUT_FILE"
echo "2. Add each secret to GitHub:"
echo "   Repository → Settings → Secrets and variables → Actions"
echo ""
echo "3. Create these secrets:"
echo "   - TEAM_ID"
echo "   - KEYCHAIN_PASSWORD"
echo "   - P12_PASSWORD"
echo "   - APPLE_ID"
echo "   - APPLE_APP_PASSWORD"
echo "   - BUILD_CERTIFICATE_BASE64"
echo ""
echo -e "${RED}4. DELETE $OUTPUT_FILE after adding secrets to GitHub!${NC}"
echo ""
echo "5. Test with a release:"
echo "   git tag v1.0.0"
echo "   git push origin v1.0.0"
echo ""
