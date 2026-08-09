#!/bin/bash

# ============================================================
# XUI.ONE License Patch - Improved Version
# ============================================================

CONFIG_FILE="/home/xui/config/config.ini"
PATCH_REPO="https://github.com/xuione/XUIPatch/raw/refs/heads/main"

# Extension paths
EXT_72="/home/xui/bin/php/lib/php/extensions/no-debug-non-zts-20170718"
EXT_74="/home/xui/bin/php/lib/php/extensions/no-debug-non-zts-20190902"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: XUI.ONE config not found at $CONFIG_FILE"
    echo "Please install XUI.ONE first and run this again."
    exit 1
fi

is_valid_license() {
    [[ "$1" =~ ^[0-9a-fA-F]{16}$ ]]
}

# Extract current license from config.ini
current_license=$(sed -n 's/^license\s*=\s*"\([^"]*\)".*/\1/p' "$CONFIG_FILE")

if ! is_valid_license "$current_license"; then
    echo "No valid license found in config.ini."
    while true; do
        read -rp "Enter license key (16 hex chars): " input_license
        if is_valid_license "$input_license"; then
            # Backup config before modifying
            cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
            sed -i "s/^license\s*=.*/license     =   \"$input_license\"/" "$CONFIG_FILE"
            echo "License updated in config.ini"
            break
        else
            echo "Invalid license! Must be 16 hexadecimal characters."
            echo ""
        fi
    done
else
    echo "License: $current_license"
fi

echo ""
echo "Patching XUI extension..."

# Backup original extensions before patching
ERRORS=0

if [ -d "$EXT_72" ]; then
    if [ -f "$EXT_72/xui.so" ]; then
        cp "$EXT_72/xui.so" "$EXT_72/xui.so.original.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    fi
    echo "Downloading PHP 7.2 extension..."
    wget -q -O "$EXT_72/xui.so" "$PATCH_REPO/extension_7.2.so"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to download PHP 7.2 extension!"
        ERRORS=$((ERRORS + 1))
    else
        echo "  -> PHP 7.2 extension patched."
    fi
else
    echo "WARNING: PHP 7.2 extension directory not found. Skipping."
fi

if [ -d "$EXT_74" ]; then
    if [ -f "$EXT_74/xui.so" ]; then
        cp "$EXT_74/xui.so" "$EXT_74/xui.so.original.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    fi
    echo "Downloading PHP 7.4 extension..."
    wget -q -O "$EXT_74/xui.so" "$PATCH_REPO/extension_7.4.so"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to download PHP 7.4 extension!"
        ERRORS=$((ERRORS + 1))
    else
        echo "  -> PHP 7.4 extension patched."
    fi
else
    echo "WARNING: PHP 7.4 extension directory not found. Skipping."
fi

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo "WARNING: $ERRORS download(s) failed. Check internet and try again."
    exit 1
fi

# Fix ownership
echo "Fixing permissions..."
chown xui:xui "$EXT_72/xui.so" 2>/dev/null
chown xui:xui "$EXT_74/xui.so" 2>/dev/null

# Restart service
echo "Restarting XUI.ONE service..."
if systemctl is-active xuione &>/dev/null; then
    sudo systemctl restart xuione
else
    sudo service xuione restart 2>/dev/null
fi

# Show status
echo ""
if [ -f /home/xui/status ]; then
    /home/xui/status
fi

echo ""
echo "Patch applied successfully!"
