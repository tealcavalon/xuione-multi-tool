#!/bin/bash

# ============================================================
# XUI.ONE MULTI-TOOL by @tealcavalon
# Improved Compatibility Edition
# Compatible: Ubuntu 20.04 / 22.04 / 24.04 / 24.10+
# ============================================================

# --- Capture credentials ---
# Support both methods: env vars (improved) and args (legacy)
# NOTE: use dedicated variable names (not USER/PASS) to avoid shadowing the
# shell's standard $USER environment variable, which other tooling may rely on.
if [ -n "$XUIONE_USER" ] && [ -n "$XUIONE_PASS" ]; then
    XUI_AUTH_USER="$XUIONE_USER"
    XUI_AUTH_PASS="$XUIONE_PASS"
elif [ -n "$1" ] && [ -n "$2" ]; then
    XUI_AUTH_USER="$1"
    XUI_AUTH_PASS="$2"
else
    echo "ERROR: No credentials provided."
    exit 1
fi

BASE_URL="tealc.pw/stuff/xuione/new"

# Multi-Tool version (the toolkit itself, NOT the XUI.ONE version). Keep this in
# sync with MULTITOOL_VERSION in the loader (newxuione.sh) on each release.
MULTITOOL_VERSION="1.5.3"

# --- MariaDB target ---
# XUI.ONE 1.5.13 is most stable on the MariaDB 10.5 series (backup/restore in the
# panel misbehaves when the installer is left to pick 10.3 or 10.6). We install and
# hold a pinned 10.5 version. MARIADB_SERIES is what we verify/accept (major.minor);
# MARIADB_VERSION is the exact archive.mariadb.org release used for the repo/pin.
MARIADB_SERIES="10.5"
MARIADB_VERSION="10.5.27"

# Re-validate for security
VALIDATE=$(wget -qO- --user="$XUI_AUTH_USER" --password="$XUI_AUTH_PASS" --user-agent="Mozilla/5.0" "https://$BASE_URL/test_user_pass" 2>/dev/null)
if [[ "$VALIDATE" != *"ok"* ]]; then
    echo "Security Violation: Unauthorized access."
    exit 1
fi

# ============================================================
# UTILITY FUNCTIONS
# ============================================================

# Detect OS version once at start
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
    elif command -v lsb_release &>/dev/null; then
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
        OS_CODENAME=$(lsb_release -sc)
    else
        echo "WARNING: Cannot detect OS version."
        OS_ID="unknown"
        OS_VERSION="unknown"
        OS_CODENAME="unknown"
    fi
    echo "Detected OS: $OS_ID $OS_VERSION ($OS_CODENAME)"
}

# Map Ubuntu version to a MariaDB archive codename
# The MariaDB archive repos only publish up to jammy (22.04); for newer Ubuntu
# we fall back to the jammy repo (works together with the lib fixes above).
get_mariadb_codename() {
    case "$OS_VERSION" in
        14.04) echo "trusty" ;;
        16.04) echo "xenial" ;;
        18.04) echo "bionic" ;;
        20.04) echo "focal" ;;
        20.10) echo "groovy" ;;
        21.04) echo "hirsute" ;;
        21.10) echo "impish" ;;
        22.04) echo "jammy" ;;
        22.10) echo "kinetic" ;;
        # Ubuntu 23.04+ / 24.04+ -> no dedicated archive repo, use jammy (last supported)
        24.04) echo "jammy" ;;
        24.10) echo "jammy" ;;
        25.04) echo "jammy" ;;
        *) echo "jammy" ;;
    esac
}

# The owner (uid:gid) of the XUI install. XUI's UID/GID frequently map to an
# unrelated system name (e.g. "fwupd-refresh:_ssh"), so "xui:xui" does not exist
# as a name on many servers - use the real numeric owner, which chown always
# accepts. Prints e.g. "1000:1000", or nothing if /home/xui is absent.
xui_owner() {
    [ -e /home/xui ] && stat -c '%u:%g' /home/xui 2>/dev/null
}

check_xui_installed() {
    if [ ! -d "/home/xui" ] || [ ! -f "/home/xui/config/config.ini" ]; then
        echo "--------------------------------------------------------"
        echo "NOTICE: XUI.ONE is not installed (/home/xui not found)."
        echo "--------------------------------------------------------"
        return 1
    fi
    return 0
}

check_xui_running() {
    if ! pgrep -f "xui" > /dev/null; then
        echo "--------------------------------------------------------"
        echo "WARNING: XUI.ONE is not currently running."
        echo "--------------------------------------------------------"
        return 1
    fi
    return 0
}

# ============================================================
# FIX COMPATIBILITY - UNIVERSAL (runs before install on any Ubuntu > 20.04)
# ============================================================

fix_compatibility() {
    echo "--- Fixing Compatibility for Ubuntu $OS_VERSION ---"

    # Compare versions: anything above 20.04 needs fixes
    if [[ "$(echo -e "20.04\n$OS_VERSION" | sort -V | tail -1)" == "20.04" ]]; then
        echo "Ubuntu 20.04 detected - no compatibility fixes needed."
        return 0
    fi

    # XUI.ONE's 1.5.13 installer targets Ubuntu 18/20 and can fail to create its
    # own 'xui' system user on 22.04+, which leaves the panel unable to run (it
    # runs AS xui, and every chown to xui:xui then fails). Create it up front,
    # before the installer, so the install and all later ownership resolve the
    # name. Idempotent; the dir /home/xui is left for the installer to create.
    echo "[+] Ensuring the 'xui' user/group exist (the installer targets 18/20)..."
    getent group xui >/dev/null 2>&1 || { sudo groupadd --system xui && echo "  -> Created group 'xui'."; }
    if id xui >/dev/null 2>&1; then
        echo "  -> 'xui' user already present."
    else
        sudo useradd --system --no-create-home --home-dir /home/xui --shell /bin/bash --gid xui xui \
            && echo "  -> Created user 'xui' (home /home/xui)."
    fi

    echo "[1/7] Installing legacy libraries..."
    cd /tmp

    # Helper: try apt first, then download .deb from archive URLs with timeout
    install_legacy_pkg() {
        local pkg="$1"
        shift
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo "  -> $pkg already installed"
            return 0
        fi
        # Try apt-get first (works on 22.04 if universe is enabled)
        if sudo apt-get install -y "$pkg" 2>/dev/null; then
            echo "  -> $pkg installed via apt"
            return 0
        fi
        # Try each archive URL until one works (with 15s timeout)
        for url in "$@"; do
            if wget --timeout=15 --tries=2 -q -O "/tmp/${pkg}.deb" "$url" 2>/dev/null && [ -s "/tmp/${pkg}.deb" ]; then
                sudo dpkg -i "/tmp/${pkg}.deb" 2>/dev/null
                rm -f "/tmp/${pkg}.deb"
                echo "  -> $pkg installed from archive"
                return 0
            fi
            rm -f "/tmp/${pkg}.deb" 2>/dev/null
        done
        echo "  WARNING: Could not install $pkg"
        return 1
    }

    # libaio1 - required by MariaDB
    install_legacy_pkg libaio1 \
        "http://archive.ubuntu.com/ubuntu/pool/main/liba/libaio/libaio1_0.3.112-13build1_amd64.deb"

    # libtinfo5 - required by some XUI binaries
    install_legacy_pkg libtinfo5 \
        "http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2_amd64.deb" \
        "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libtinfo5_6.3-2ubuntu0.1_amd64.deb"

    # libncurses5 - required by some XUI binaries
    install_legacy_pkg libncurses5 \
        "http://archive.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2_amd64.deb" \
        "http://security.ubuntu.com/ubuntu/pool/universe/n/ncurses/libncurses5_6.3-2ubuntu0.1_amd64.deb"

    # libjpeg.so.8 / libpng / libwebp - XUI's bundled PHP (libgd) needs these;
    # on 22.04+ libjpeg8 is gone, so `./status` fails with "libjpeg.so.8: cannot
    # open shared object file". These are all in the normal repos.
    install_legacy_pkg libjpeg-turbo8
    install_legacy_pkg libpng16-16
    install_legacy_pkg libwebp7

    # Report any shared libs still missing for XUI's PHP, so the next libFoo.so.N
    # to install is named rather than found by trial and error.
    if [ -x /home/xui/bin/php/bin/php ]; then
        MISSING_SO=$(ldd /home/xui/bin/php/bin/php 2>/dev/null | awk '/not found/{print $1}' | sort -u)
        if [ -n "$MISSING_SO" ]; then
            echo "  -> WARNING: XUI PHP still missing shared libraries:"
            echo "$MISSING_SO" | sed 's/^/         /'
            echo "     Install the package that provides each (try: apt-file search <lib>)."
        else
            echo "  -> XUI PHP shared libraries: OK"
        fi
    fi

    # libssl1.1 - critical for XUI PHP and nginx binaries
    echo "[2/7] Checking libssl1.1..."
    if ! ldconfig -p | grep -q "libssl.so.1.1"; then
        wget --timeout=15 --tries=2 -q -O /tmp/libssl1.1_1.1.1f-1ubuntu2_amd64.deb \
            http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl1.1_1.1.1f-1ubuntu2_amd64.deb 2>/dev/null
        if [ -f /tmp/libssl1.1_1.1.1f-1ubuntu2_amd64.deb ]; then
            sudo dpkg -i /tmp/libssl1.1_1.1.1f-1ubuntu2_amd64.deb 2>/dev/null
            rm -f /tmp/libssl1.1_1.1.1f-1ubuntu2_amd64.deb
        fi
    fi

    # libaio.so.1 symlink for Ubuntu 24.04+ (libaio1t64 transition)
    echo "[3/7] Checking libaio symlinks..."
    if [ ! -f /usr/lib/x86_64-linux-gnu/libaio.so.1 ]; then
        sudo apt-get update -qq
        sudo apt-get install -y libaio1t64 2>/dev/null
        if [ -f /usr/lib/x86_64-linux-gnu/libaio.so.1t64 ]; then
            sudo ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1
        fi
    fi

    # AppArmor restriction on Ubuntu 24.04+
    echo "[4/7] Checking AppArmor restrictions..."
    if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
        CURRENT_VAL=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)
        if [ "$CURRENT_VAL" == "1" ]; then
            sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
            if ! grep -q "apparmor_restrict_unprivileged_userns" /etc/sysctl.conf; then
                echo "kernel.apparmor_restrict_unprivileged_userns=0" | sudo tee -a /etc/sysctl.conf
            fi
        fi
    fi

    # Handle package name transitions (t64)
    echo "[5/7] Handling package name transitions..."
    # libssh2-1 vs libssh2-1t64
    if ! dpkg -l libssh2-1 2>/dev/null | grep -q "^ii"; then
        if apt-cache show libssh2-1 &>/dev/null; then
            sudo apt-get install -y libssh2-1 2>/dev/null
        elif apt-cache show libssh2-1t64 &>/dev/null; then
            sudo apt-get install -y libssh2-1t64 2>/dev/null
        fi
    fi

    # Fix certbot/Let's Encrypt for XUI.ONE on Ubuntu 22.04/24.04
    # XUI.ONE uses the system certbot binary but with its own directories:
    #   --config-dir /home/xui/bin/certbot/config
    #   --work-dir   /home/xui/bin/certbot/work
    #   --logs-dir   /home/xui/bin/certbot/logs
    #
    # TWO problems on Ubuntu 22/24:
    #   1) Snap certbot has strict confinement - can't access XUI custom dirs
    #   2) Certbot 2.x changed output format: XUI.ONE PHP code parses for
    #      "certificate and chain have been saved at" (certbot 1.x format)
    #      but certbot 2.x outputs "Certificate is saved at: /path/..."
    #      This causes the cert to be generated but NOT installed in ssl.conf/DB
    #
    # Solution: Install non-snap certbot + create a wrapper that translates
    # certbot 2.x output back to the 1.x format XUI.ONE expects
    echo "[6/7] Fixing certbot/Let's Encrypt for XUI.ONE..."

    # Step 1: Remove snap certbot if installed (it can't access XUI directories)
    if snap list certbot &>/dev/null 2>&1; then
        echo "  -> Removing snap certbot (incompatible with XUI.ONE custom dirs)..."
        sudo snap remove certbot 2>/dev/null
        sudo rm -f /snap/bin/certbot 2>/dev/null
    fi

    # Step 2: Install certbot via apt (classic package, no sandbox restrictions)
    # First check if a real (non-wrapper) certbot exists
    REAL_CERTBOT=""
    if [ -x /usr/bin/certbot ]; then
        REAL_CERTBOT="/usr/bin/certbot"
    elif [ -x /opt/certbot-xui/bin/certbot ]; then
        REAL_CERTBOT="/opt/certbot-xui/bin/certbot"
    fi

    if [ -z "$REAL_CERTBOT" ]; then
        echo "  -> Installing certbot via apt..."
        sudo apt-get install -y certbot 2>/dev/null
        if [ -x /usr/bin/certbot ]; then
            REAL_CERTBOT="/usr/bin/certbot"
        fi
    fi

    # Step 3: If apt certbot still not available, install via pip3 in a dedicated venv
    if [ -z "$REAL_CERTBOT" ]; then
        echo "  -> apt certbot unavailable, installing via pip3..."
        # Detect Python version for correct venv package (e.g. python3.12-venv on Ubuntu 24.04)
        PY_VER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        if [ -n "$PY_VER" ]; then
            sudo apt-get install -y "python${PY_VER}-venv" python3-pip 2>/dev/null
        else
            sudo apt-get install -y python3-venv python3-pip 2>/dev/null
        fi
        CERTBOT_VENV="/opt/certbot-xui"
        if [ ! -d "$CERTBOT_VENV" ]; then
            sudo python3 -m venv "$CERTBOT_VENV"
        fi
        sudo "$CERTBOT_VENV/bin/pip" install --upgrade pip 2>/dev/null
        sudo "$CERTBOT_VENV/bin/pip" install certbot 2>/dev/null
        REAL_CERTBOT="/opt/certbot-xui/bin/certbot"
        echo "  -> Certbot installed via pip3 at $CERTBOT_VENV"
    fi

    # Step 4: Create wrapper script that translates certbot 2.x output to 1.x format
    # XUI.ONE's PHP (includes/cli/certbot.php) parses exec() output looking for:
    #   - "certificate and chain have been saved at" → then reads next line for path
    #   - "the dry run was successful" → dry run OK
    #   - "cert not yet due for renewal" → skip renewal
    # Certbot 2.x outputs:
    #   - "Certificate is saved at: /path/to/fullchain.pem" (same line, different text)
    #   - "Successfully received certificate." (no path on same line)
    # The wrapper translates 2.x → 1.x format so XUI.ONE can parse it correctly
    if [ -n "$REAL_CERTBOT" ]; then
        echo "  -> Installing certbot wrapper for XUI.ONE compatibility..."
        sudo tee /usr/local/bin/certbot > /dev/null << 'WRAPPER_EOF'
#!/bin/bash
# XUI.ONE certbot compatibility wrapper
# Translates certbot 2.x output to 1.x format for XUI.ONE PHP parsing
#
# XUI.ONE expects: "certificate and chain have been saved at:\n   /path/fullchain.pem"
# Certbot 2.x gives: "Certificate is saved at: /path/fullchain.pem"

# Find the real certbot binary (not this wrapper)
REAL=""
for candidate in /usr/bin/certbot /opt/certbot-xui/bin/certbot; do
    if [ -x "$candidate" ]; then
        REAL="$candidate"
        break
    fi
done

if [ -z "$REAL" ]; then
    echo "Error: certbot binary not found" >&2
    exit 1
fi

# Run real certbot, capture output and exit code
OUTPUT=$("$REAL" "$@" 2>&1)
EXIT_CODE=$?

# Translate certbot 2.x output to 1.x format
# Pattern 1: "Certificate is saved at: /path/to/fullchain.pem"
#         →  "Your certificate and chain have been saved at:\n   /path/to/fullchain.pem"
# Pattern 2: "Key is saved at: /path/to/privkey.pem"
#         →  "Your key file has been saved at:\n   /path/to/privkey.pem"
echo "$OUTPUT" | sed \
    -e 's|Certificate is saved at: *\(.*\)|Your certificate and chain have been saved at:\n   \1|' \
    -e 's|Key is saved at: *\(.*\)|Your key file has been saved at:\n   \1|'

exit $EXIT_CODE
WRAPPER_EOF
        sudo chmod +x /usr/local/bin/certbot
        echo "  -> Wrapper installed at /usr/local/bin/certbot -> $REAL_CERTBOT"
    fi

    # Step 5: Ensure XUI.ONE certbot directories exist with proper ownership
    if [ -d /home/xui ]; then
        echo "  -> Ensuring XUI certbot directories..."
        sudo mkdir -p /home/xui/bin/certbot/{config,work,logs}
        XO=$(xui_owner)
        [ -n "$XO" ] && sudo chown -R "$XO" /home/xui/bin/certbot/
    fi

    # Step 6: Fix existing certificates that were generated but not installed
    # This handles the case where certbot 2.x already generated certs before
    # the wrapper was installed - ssl.conf was never updated
    if [ -d /home/xui/bin/certbot/config/live ] && [ -d /home/xui/bin/nginx/conf ]; then
        SSL_CONF="/home/xui/bin/nginx/conf/ssl.conf"
        # Check if ssl.conf still points to default self-signed cert
        if [ -f "$SSL_CONF" ] && grep -q "server.crt" "$SSL_CONF" 2>/dev/null; then
            # Find the newest valid certificate in certbot's live directory
            BEST_CERT_DIR=""
            for CERT_DIR in /home/xui/bin/certbot/config/live/*/; do
                if [ -f "${CERT_DIR}fullchain.pem" ] && [ -f "${CERT_DIR}privkey.pem" ] && [ -f "${CERT_DIR}chain.pem" ]; then
                    BEST_CERT_DIR="$CERT_DIR"
                fi
            done

            if [ -n "$BEST_CERT_DIR" ]; then
                echo "  -> Found existing certificate in $BEST_CERT_DIR"
                echo "  -> Updating ssl.conf (was still pointing to self-signed cert)..."
                FULLCHAIN="${BEST_CERT_DIR}fullchain.pem"
                PRIVKEY="${BEST_CERT_DIR}privkey.pem"
                CHAIN="${BEST_CERT_DIR}chain.pem"
                sudo cp "$SSL_CONF" "${SSL_CONF}.bak.$(date +%Y%m%d%H%M%S)"
                sudo tee "$SSL_CONF" > /dev/null << SSLEOF
ssl_certificate ${FULLCHAIN};
ssl_certificate_key ${PRIVKEY};
ssl_trusted_certificate ${CHAIN};
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
ssl_prefer_server_ciphers off;
ssl_ecdh_curve auto;
ssl_session_timeout 10m;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;
SSLEOF
                XO=$(xui_owner)
                [ -n "$XO" ] && sudo chown "$XO" "$SSL_CONF"
                echo "  -> ssl.conf updated! Reloading nginx..."
                sudo /home/xui/bin/nginx/sbin/nginx -s reload 2>/dev/null
                echo "  -> NOTE: The XUI panel DB will be updated on next certbot cron run."
                echo "     You can also restart XUI: sudo systemctl restart xuione"
            fi
        fi
    fi

    # Step 7: Verify certbot is working
    if [ -x /usr/local/bin/certbot ]; then
        CERTBOT_VER=$(/usr/local/bin/certbot --version 2>&1 | grep -oP '[0-9]+\.[0-9]+\.?[0-9]*' | head -1)
        echo "  -> Certbot $CERTBOT_VER ready (with XUI.ONE compatibility wrapper)"
    else
        echo "  -> WARNING: Could not install certbot. SSL certificates via Let's Encrypt will not work."
        echo "     You can install it manually: sudo apt install certbot"
    fi

    # ---------------------------------------------------------------
    # [7/7] SSH legacy algorithm compatibility for XUI Load Balancer
    # ---------------------------------------------------------------
    # XUI.ONE's built-in SSH client (libssh2, old version) requires the
    # 'ssh-rsa' host key algorithm (RSA/SHA-1) to install Load Balancers.
    # Ubuntu 22.04+ / OpenSSH 8.8+ disabled ssh-rsa by default, causing
    # "Failed to connect to server" when adding an LB from the panel.
    #
    # This re-enables legacy algorithms in a drop-in config file.
    # Only applies if ssh-rsa is not already offered. Idempotent.
    echo "[7/7] Checking SSH legacy algorithms for XUI Load Balancer..."

    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then
        # Check if ssh-rsa is already offered
        CUR_HOSTKEYALGOS=$(sshd -T 2>/dev/null | awk '/^hostkeyalgorithms /{print $2}')
        if echo ",$CUR_HOSTKEYALGOS," | grep -q ',ssh-rsa,'; then
            echo "  -> ssh-rsa already offered - LB installation will work."
        else
            echo "  -> ssh-rsa is DISABLED (Ubuntu 22.04+/OpenSSH 8.8+)."
            echo "     XUI LB client cannot negotiate. Enabling legacy compat..."

            SSHD_MAIN_CFG="/etc/ssh/sshd_config"
            SSHD_COMPAT_FILE="/etc/ssh/sshd_config.d/99-xui-compat.conf"

            # Helper: check which legacy algorithms this OpenSSH version supports
            pick_supported() {
                local list="$1"; shift; local out="" a
                for a in "$@"; do
                    echo "$list" | grep -qx "$a" && out="$out,$a"
                done
                echo "${out#,}"
            }

            COMPAT_KEX=$(pick_supported "$(ssh -Q kex 2>/dev/null)" \
                diffie-hellman-group14-sha1 diffie-hellman-group1-sha1 diffie-hellman-group-exchange-sha1)
            COMPAT_CIPHERS=$(pick_supported "$(ssh -Q cipher 2>/dev/null)" aes256-cbc aes128-cbc 3des-cbc)
            COMPAT_MACS=$(pick_supported "$(ssh -Q mac 2>/dev/null)" hmac-sha1)

            # Backup sshd_config
            SSHD_BAK_TS=$(date +%Y%m%d%H%M%S)
            cp -a "$SSHD_MAIN_CFG" "${SSHD_MAIN_CFG}.bak.${SSHD_BAK_TS}"

            # Write drop-in compat config
            {
                echo "# XUI Load Balancer SSH compat (auto ${SSHD_BAK_TS})"
                echo "# Re-enables legacy algorithms required by XUI's libssh2 client"
                echo "HostKeyAlgorithms +ssh-rsa"
                echo "PubkeyAcceptedAlgorithms +ssh-rsa"
                echo "CASignatureAlgorithms +ssh-rsa"
                [ -n "$COMPAT_KEX" ]     && echo "KexAlgorithms +$COMPAT_KEX"
                [ -n "$COMPAT_CIPHERS" ] && echo "Ciphers +$COMPAT_CIPHERS"
                [ -n "$COMPAT_MACS" ]    && echo "MACs +$COMPAT_MACS"
            } > "$SSHD_COMPAT_FILE"

            # Ensure RSA host key exists
            [ -f /etc/ssh/ssh_host_rsa_key ] || \
                ssh-keygen -t rsa -b 2048 -f /etc/ssh/ssh_host_rsa_key -N '' >/dev/null 2>&1

            # Ensure Include directive is in GLOBAL scope (before any Match block)
            FIRST_MATCH_LINE=$(grep -niE '^[[:space:]]*Match([[:space:]]|$)' "$SSHD_MAIN_CFG" | head -1 | cut -d: -f1)
            INC_LINE=$(grep -niE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN_CFG" | head -1 | cut -d: -f1)
            GLOBAL_INC=0
            if [ -n "$INC_LINE" ]; then
                { [ -z "$FIRST_MATCH_LINE" ] || [ "$INC_LINE" -lt "$FIRST_MATCH_LINE" ]; } && GLOBAL_INC=1
            fi
            if [ "$GLOBAL_INC" -eq 0 ]; then
                { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat "$SSHD_MAIN_CFG"; } > "${SSHD_MAIN_CFG}.tmp" \
                    && mv "${SSHD_MAIN_CFG}.tmp" "$SSHD_MAIN_CFG"
                echo "  -> Added global Include to top of sshd_config."
            fi

            # Validate config; rollback if broken
            if ! sshd -t 2>/tmp/xui_sshd_err; then
                echo "  ERROR: sshd config test failed. Rolling back:"
                cat /tmp/xui_sshd_err
                mv "${SSHD_MAIN_CFG}.bak.${SSHD_BAK_TS}" "$SSHD_MAIN_CFG"
                rm -f "$SSHD_COMPAT_FILE"
            else
                # Verify ssh-rsa is now offered
                NEW_HOSTKEYALGOS=$(sshd -T 2>/dev/null | awk '/^hostkeyalgorithms /{print $2}')
                if echo ",$NEW_HOSTKEYALGOS," | grep -q ',ssh-rsa,'; then
                    # Restart SSH service
                    if systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null; then
                        echo "  -> SSH legacy compat applied and service restarted."
                        echo "     XUI LB 'Install Server' will now connect successfully."
                    else
                        echo "  -> Config applied but SSH restart failed. Restart manually: systemctl restart ssh"
                    fi
                else
                    echo "  WARNING: ssh-rsa still not offered after config change. Rolling back."
                    mv "${SSHD_MAIN_CFG}.bak.${SSHD_BAK_TS}" "$SSHD_MAIN_CFG"
                    rm -f "$SSHD_COMPAT_FILE"
                fi
            fi
        fi
    else
        echo "  -> sshd not found or config invalid - skipping SSH compat."
    fi

    echo "--- Compatibility fixes applied ---"
}

# ============================================================
# FORCE MARIADB (pinned series - see MARIADB_SERIES / MARIADB_VERSION)
# ============================================================

force_mariadb() {
    echo "--- Ensuring MariaDB $MARIADB_SERIES (target $MARIADB_VERSION) ---"

    NEED_INSTALL=true

    # Check if MariaDB is already installed and which version
    if command -v mariadb &>/dev/null || command -v mysql &>/dev/null; then
        INSTALLED_VER=$(mysql -V 2>/dev/null | grep -oP 'Distrib \K[0-9]+\.[0-9]+' || echo "unknown")
        echo "Currently installed MariaDB/MySQL version: $INSTALLED_VER"
        if [[ "$INSTALLED_VER" == "$MARIADB_SERIES" ]]; then
            NEED_INSTALL=false
        else
            echo "Version $INSTALLED_VER detected. Replacing with MariaDB $MARIADB_SERIES..."
            sudo systemctl stop mariadb 2>/dev/null
            sudo systemctl stop mysql 2>/dev/null
            # Unhold before removing (in case they were held from a previous run)
            dpkg -l | grep -iE "mariadb|galera|mysql" | grep "^ii" | awk '{print $2}' | xargs -r sudo apt-mark unhold 2>/dev/null
            sudo apt-get remove --purge -y mariadb-server mariadb-client mysql-server mysql-client 2>/dev/null
            sudo apt-get autoremove -y 2>/dev/null
        fi
    fi

    if $NEED_INSTALL; then
        # Add MariaDB repo
        MARIA_CODENAME=$(get_mariadb_codename)
        echo "Using MariaDB $MARIADB_VERSION repo with codename: $MARIA_CODENAME"

        # Import MariaDB signing key
        sudo apt-get install -y apt-transport-https curl gnupg 2>/dev/null
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://mariadb.org/mariadb_release_signing_key.pgp | sudo gpg --dearmor --yes -o /etc/apt/keyrings/mariadb-keyring.gpg 2>/dev/null

        # Add repository - using archive.mariadb.org (dlm.mariadb.com returns 404)
        MARIADB_REPO="https://archive.mariadb.org/mariadb-${MARIADB_VERSION}/repo/ubuntu"
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/mariadb-keyring.gpg] $MARIADB_REPO $MARIA_CODENAME main" | \
            sudo tee /etc/apt/sources.list.d/mariadb.list

        # Remove legacy repo/preferences files left by older tool versions (e.g. 10.6)
        sudo rm -f /etc/apt/preferences.d/mariadb-10.6 \
                   /etc/apt/preferences.d/mariadb-10.6.pref \
                   /etc/apt/sources.list.d/mariadb-10.6.list

        # Pin MariaDB to archive.mariadb.org to prevent repo-level upgrades
        cat <<PINEOF | sudo tee /etc/apt/preferences.d/mariadb.pref
Package: mariadb-*
Pin: origin archive.mariadb.org
Pin-Priority: 1000

Package: libmariadb*
Pin: origin archive.mariadb.org
Pin-Priority: 1000

Package: galera-*
Pin: origin archive.mariadb.org
Pin-Priority: 1000
PINEOF

        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server mariadb-client

        # Verify install
        FINAL_VER=$(mysql -V 2>/dev/null | grep -oP 'Distrib \K[0-9]+\.[0-9]+' || echo "failed")
        if [[ "$FINAL_VER" != "$MARIADB_SERIES" ]]; then
            echo "WARNING: MariaDB installation may have issues. Expected $MARIADB_SERIES, detected: $FINAL_VER"
            return 1
        fi
    fi

    # ALWAYS hold packages - whether freshly installed or already present
    MARIA_PKGS=$(dpkg -l | grep -i mariadb | grep "^ii" | awk '{print $2}')
    GALERA_PKGS=$(dpkg -l | grep -i galera | grep "^ii" | awk '{print $2}')
    ALL_HOLD_PKGS=""
    for pkg in $MARIA_PKGS $GALERA_PKGS mysql-common; do
        sudo apt-mark hold "$pkg" 2>/dev/null && ALL_HOLD_PKGS="$ALL_HOLD_PKGS $pkg"
    done

    # Summary
    echo ""
    echo "=========================================="
    echo " MariaDB $MARIADB_SERIES - Status"
    echo "=========================================="
    echo " Version:  $(mysql -V 2>/dev/null | grep -oP 'Distrib \K[0-9.]+' || echo 'N/A')"
    if $NEED_INSTALL; then
        echo " Action:   Freshly installed"
    else
        echo " Action:   Already installed (skipped)"
    fi
    echo " Packages on hold (upgrade blocked):"
    apt-mark showhold | grep -iE "mariadb|galera|mysql" | while read p; do echo "   - $p"; done
    echo "=========================================="
}

# ============================================================
# INSTALL XUI.ONE
# ============================================================

install_xui() {
    echo "--- Preparing XUI.ONE 1.5.13 ---"

    # Pick a random license key silently
    LICENSES=("7a4d9c3b1f82e670" "3f8a29c1b74d56e2" "bc4e90f1832a1d7c")
    XUI_LICENSE="${LICENSES[$((RANDOM % ${#LICENSES[@]}))]}"

    detect_os
    echo "Detected OS: $OS_ID $OS_VERSION ($OS_CODENAME)"

    # Callers that already ran fix_compatibility + force_mariadb (e.g. run_full_setup)
    # pass "skip-fixes" so we don't do the whole compatibility/MariaDB pass twice.
    if [[ "$1" == "skip-fixes" ]]; then
        echo "Pre-install compatibility/MariaDB already handled by caller - skipping."
    elif [[ "$OS_VERSION" == "20.04" ]]; then
        # Ubuntu 20.04: XUI.ONE installer handles everything natively, no fixes needed
        echo "Ubuntu 20.04 detected - no compatibility fixes required."
    else
        # Ubuntu 22.04+ needs compatibility fixes and our pinned MariaDB series
        fix_compatibility
        force_mariadb
    fi

    read -p "Press [Enter] to start XUI installation..."

    cd /tmp

    sudo apt-get update && sudo apt-get install -y unzip wget software-properties-common

    if [[ "$OS_VERSION" != "20.04" ]]; then
        # Install MaxMind GeoIP (required by XUI.ONE, already in 20.04 repos via installer)
        echo "Installing MaxMind GeoIP libraries..."
        if ! sudo apt-get install -y libmaxminddb0 libmaxminddb-dev geoipupdate 2>/dev/null; then
            echo "  -> Packages not in default repos, trying MaxMind PPA..."
            sudo add-apt-repository -y ppa:maxmind/ppa 2>/dev/null
            sudo apt-get update -qq
            sudo apt-get install -y libmaxminddb0 libmaxminddb-dev geoipupdate 2>/dev/null
        fi
        if dpkg -l libmaxminddb0 &>/dev/null; then
            echo "  -> MaxMind GeoIP: OK"
        else
            echo "  -> WARNING: MaxMind GeoIP could not be installed."
        fi
    fi

    echo "Downloading XUI_1.5.13.zip..."
    wget --user="$XUI_AUTH_USER" --password="$XUI_AUTH_PASS" --user-agent="Mozilla/5.0" \
        "https://$BASE_URL/XUI_1.5.13.zip" -O XUI_1.5.13.zip

    if [ ! -f XUI_1.5.13.zip ]; then
        echo "ERROR: Download failed!"
        return 1
    fi

    unzip -o XUI_1.5.13.zip

    # Patch the install script to handle package name transitions
    if [ -f ./install ]; then
        # Fix libssh2-1t64 for Ubuntu 20.04 (where it's called libssh2-1)
        if [[ "$OS_VERSION" == "20.04" || "$OS_VERSION" == "18.04" ]]; then
            sed -i 's/libssh2-1t64/libssh2-1/g' ./install
        fi

        # Auto-fill the license key in the Python installer
        # Replace the input() call with our pre-selected license
        sed -i 's/rLicense = input("Enter License Key: ")/rLicense = "'"$XUI_LICENSE"'"/g' ./install 2>/dev/null
        # Also print confirmation so user sees it
        sed -i 's/print("License Installed")/print("License Installed: '"$XUI_LICENSE"'")/g' ./install 2>/dev/null

        # Disable the dead DigitalOcean MariaDB repo that the installer tries to add
        # (ams2.mirrors.digitalocean.com no longer resolves - we already have archive.mariadb.org)
        # Comment out instead of deleting to preserve Python indentation/syntax
        sed -i 's/.*ams2.mirrors.digitalocean.com.*/#&/' ./install 2>/dev/null
        sed -i 's/.*0xF1656F24C74CD1D8.*/#&/' ./install 2>/dev/null

        # Skip the libssl1.1 downgrade - we already have it or handled it in fix_compatibility
        sed -i 's/.*libssl1.1_1.1.1f-1ubuntu2_amd64.*/#&/' ./install 2>/dev/null

        chmod +x ./install
        sudo ./install
    else
        echo "ERROR: install script not found in ZIP!"
        return 1
    fi

    # NOTE: The 1.5.13 ZIP already includes cracked files, so no patch needed
    # after a fresh install. apply_patch remains available in TOOLS for other versions.

    # Hold MariaDB/MySQL packages to prevent accidental upgrades
    # On Ubuntu 20.04 the original installer installs MariaDB, so we hold those packages
    # On Ubuntu 22/24 force_mariadb already does this
    if [[ "$OS_VERSION" == "20.04" ]]; then
        echo ""
        echo "--- Holding MariaDB/MySQL packages ---"
        MARIA_PKGS=$(dpkg -l | grep -i mariadb | grep "^ii" | awk '{print $2}')
        GALERA_PKGS=$(dpkg -l | grep -i galera | grep "^ii" | awk '{print $2}')
        for pkg in $MARIA_PKGS $GALERA_PKGS mysql-common; do
            sudo apt-mark hold "$pkg" 2>/dev/null
        done
        echo "Packages on hold:"
        apt-mark showhold | grep -iE "mariadb|galera|mysql" | while read p; do echo "  - $p"; done
    fi

    # Show credentials generated by the installer
    echo ""
    echo "=========================================="
    echo " INSTALLATION CREDENTIALS"
    echo "=========================================="
    if [ -f /tmp/credentials.txt ]; then
        cat /tmp/credentials.txt
    else
        echo "WARNING: /tmp/credentials.txt not found."
    fi
    echo "=========================================="
    echo ""

    # Ask if user wants to import a database
    read -p "  $(echo -e "${C}Do you want to import a database now? (Y/N): ${N}")" import_confirm
    if [[ "$import_confirm" =~ ^[Yy]$ ]]; then
        import_database
    fi

    # Reboot recommended after installation
    echo ""
    echo -e "  ${R}╔══════════════════════════════════════════════════╗${N}"
    echo -e "  ${R}║  A server reboot is recommended to complete     ║${N}"
    echo -e "  ${R}║  the installation.                              ║${N}"
    echo -e "  ${R}╚══════════════════════════════════════════════════╝${N}"
    echo ""
    read -p "  Reboot now? (Y/N): " reboot_confirm
    if [[ "$reboot_confirm" =~ ^[Yy]$ ]]; then
        echo "  Rebooting..."
        sudo reboot
    else
        echo ""
        echo -e "  ${R}WARNING: The server was NOT rebooted.${N}"
        echo -e "  ${R}XUI.ONE may not function correctly until the server is rebooted.${N}"
        echo -e "  ${R}To reboot manually later: sudo reboot${N}"
        echo ""
    fi
}

# ============================================================
# APPLY PATCH
# ============================================================

apply_patch() {
    echo "--- Applying License Removal Patch ---"
    bash <(wget -qO- --user="$XUI_AUTH_USER" --password="$XUI_AUTH_PASS" --user-agent="Mozilla/5.0" "https://$BASE_URL/patch.sh")
}

# ============================================================
# HARDWARE OPTIMIZER (improved: actually applies changes)
# ============================================================

optimize_server() {
    if ! check_xui_installed; then return; fi

    sudo apt-get update -y && sudo apt-get install -y ethtool util-linux grep coreutils bc

    CPU_CORES=$(nproc 2>/dev/null || lscpu | grep -E '^CPU\(s\):' | awk '{print $2}')
    TOTAL_RAM_GB=$(free -g | grep Mem: | awk '{print $2}')
    IS_SSD=$(lsblk -d -o NAME,ROTA 2>/dev/null | grep -v NAME | awk '{sum+=$2} END {if (sum==0) print "YES"; else print "NO"}')

    echo "=========================================="
    echo " Hardware Detected:"
    echo "   CPU Cores:  $CPU_CORES"
    echo "   RAM:        ${TOTAL_RAM_GB}GB"
    echo "   SSD:        $IS_SSD"
    echo "=========================================="
    echo ""
    echo " 1) MAIN Server (high MySQL buffer, full optimization)"
    echo " 2) Load Balancer (minimal MySQL, stream-focused)"
    echo " 3) Skip"
    read -p "Select role: " ROLE

    if [ "$ROLE" == "3" ]; then return; fi

    if [ "$ROLE" == "1" ]; then
        # MAIN server: 70% RAM for InnoDB
        BUFF=$(echo "($TOTAL_RAM_GB * 70 / 100)" | bc)
        [ "$BUFF" -lt 1 ] && BUFF=1
        IO_CAP=5000
        IO_CAP_MAX=10000
        POOL_INSTANCES=$(( BUFF > 1 ? BUFF : 1 ))
        [ "$POOL_INSTANCES" -gt 64 ] && POOL_INSTANCES=64
        READ_THREADS=$(( CPU_CORES > 4 ? CPU_CORES : 4 ))
        WRITE_THREADS=$(( CPU_CORES > 4 ? CPU_CORES : 4 ))
        THREAD_POOL=$(( CPU_CORES ))
    elif [ "$ROLE" == "2" ]; then
        # LB: minimal MySQL
        BUFF=1
        IO_CAP=1000
        IO_CAP_MAX=2000
        POOL_INSTANCES=1
        READ_THREADS=4
        WRITE_THREADS=4
        THREAD_POOL=$(( CPU_CORES ))
    fi

    echo ""
    echo "Proposed MySQL Configuration:"
    echo "  innodb_buffer_pool_size    = ${BUFF}G"
    echo "  innodb_buffer_pool_instances = $POOL_INSTANCES"
    echo "  innodb_io_capacity         = $IO_CAP"
    echo "  innodb_io_capacity_max     = $IO_CAP_MAX"
    echo "  innodb_read_io_threads     = $READ_THREADS"
    echo "  innodb_write_io_threads    = $WRITE_THREADS"
    echo "  thread_pool_size           = $THREAD_POOL"
    echo ""
    read -p "Apply this tuning now? (y/n): " APPLY

    if [[ "$APPLY" != "y" && "$APPLY" != "Y" ]]; then
        echo "Skipped."
    else
        # Write a dedicated drop-in instead of editing my.cnf in place.
        # Editing my.cnf with sed only works if each key already exists at the
        # start of a line. On XUI installs the InnoDB settings usually live in an
        # included mariadb.conf.d/*.cnf, so the old sed approach silently changed
        # NOTHING (buffer pool never updated). A 99- drop-in is read last by
        # MariaDB and reliably overrides any earlier value.
        if [ -d /etc/mysql/mariadb.conf.d ]; then
            TUNING_DIR="/etc/mysql/mariadb.conf.d"
        elif [ -d /etc/mysql/conf.d ]; then
            TUNING_DIR="/etc/mysql/conf.d"
        else
            TUNING_DIR="/etc/mysql/mariadb.conf.d"
            sudo mkdir -p "$TUNING_DIR"
        fi
        TUNING_FILE="$TUNING_DIR/99-xui-tuning.cnf"

        # Backup an existing drop-in before overwriting
        [ -f "$TUNING_FILE" ] && sudo cp "$TUNING_FILE" "${TUNING_FILE}.bak.$(date +%Y%m%d%H%M%S)"

        sudo tee "$TUNING_FILE" > /dev/null <<TUNEOF
# XUI Multi-Tool hardware tuning (role $ROLE) - generated $(date '+%Y-%m-%d %H:%M:%S')
[mysqld]
innodb_buffer_pool_size         = ${BUFF}G
innodb_buffer_pool_instances    = $POOL_INSTANCES
innodb_io_capacity              = $IO_CAP
innodb_io_capacity_max          = $IO_CAP_MAX
innodb_read_io_threads          = $READ_THREADS
innodb_write_io_threads         = $WRITE_THREADS
thread_pool_size                = $THREAD_POOL
TUNEOF
        echo "Tuning written to $TUNING_FILE"

        echo "Restarting MariaDB..."
        if sudo systemctl restart mariadb 2>/dev/null || sudo service mariadb restart 2>/dev/null; then
            sleep 2
            if systemctl is-active mariadb &>/dev/null || pgrep -x mariadbd >/dev/null || pgrep -x mysqld >/dev/null; then
                # Validate the values actually took effect (best-effort; needs root auth)
                ACTUAL_BUFF=$(mysql -u root -N -e "SELECT ROUND(@@innodb_buffer_pool_size/1024/1024/1024,2);" 2>/dev/null)
                ACTUAL_INST=$(mysql -u root -N -e "SELECT @@innodb_buffer_pool_instances;" 2>/dev/null)
                echo ""
                echo "Live values after restart:"
                echo "  innodb_buffer_pool_size      = ${ACTUAL_BUFF:-?} G (requested ${BUFF}G)"
                echo "  innodb_buffer_pool_instances = ${ACTUAL_INST:-?} (requested $POOL_INSTANCES)"
                if [ -n "$ACTUAL_BUFF" ] && [ "${ACTUAL_BUFF%.*}" -ge 1 ] 2>/dev/null; then
                    echo "Tuning verified."
                else
                    echo "NOTE: Could not confirm via SQL (root password required?)."
                    echo "      Check manually: SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
                fi
            else
                echo "ERROR: MariaDB did not come back up after restart!"
                echo "The tuning may be invalid. Inspect: journalctl -u mariadb -n 50"
                echo "Revert with: sudo rm $TUNING_FILE && sudo systemctl restart mariadb"
            fi
        else
            echo "ERROR: MariaDB restart failed. Tuning written but not active."
            echo "Inspect: journalctl -u mariadb -n 50"
        fi
    fi

    # Kernel TCP optimization (sysctl)
    echo ""
    read -p "Also apply kernel TCP/network optimizations? (y/n): " APPLY_SYSCTL
    if [[ "$APPLY_SYSCTL" == "y" || "$APPLY_SYSCTL" == "Y" ]]; then
        sudo sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
        sudo sysctl -w net.core.default_qdisc=fq 2>/dev/null
        sudo sysctl -w net.core.somaxconn=1000000 2>/dev/null
        sudo sysctl -w net.core.netdev_max_backlog=250000 2>/dev/null
        sudo sysctl -w net.ipv4.tcp_max_tw_buckets=1440000 2>/dev/null
        sudo sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null
        sudo sysctl -w net.ipv4.tcp_keepalive_time=300 2>/dev/null
        sudo sysctl -w fs.file-max=20970800 2>/dev/null
        sudo sysctl -w fs.nr_open=20970800 2>/dev/null
        echo "Kernel optimizations applied."
    fi
}

# ============================================================
# SECURE MYSQL (fixed iptables ordering)
# ============================================================

secure_mysql() {
    if ! check_xui_installed; then return; fi

    echo "--- Securing MySQL (port 3306) ---"

    sudo apt-get install -y iptables-persistent 2>/dev/null
    if ! command -v netfilter-persistent &>/dev/null; then
        echo "NOTE: netfilter-persistent is not available - rules will be written to"
        echo "      /etc/iptables/rules.v4(.v6) as a fallback, but may not auto-restore"
        echo "      on boot unless your system loads them. Verify persistence after reboot."
    fi

    # Detect whether an IPv6 firewall is usable (some hosts disable IPv6 entirely).
    # Without this, port 3306 would stay wide open over IPv6 while we lock down IPv4.
    HAS_IP6=0
    if command -v ip6tables &>/dev/null && sudo ip6tables -L -n &>/dev/null; then
        HAS_IP6=1
    fi

    # Flush any existing MySQL rules to start clean
    echo "Flushing existing MySQL firewall rules..."
    sudo iptables -D INPUT -p tcp --dport 3306 -j DROP 2>/dev/null
    sudo iptables -F MYSQL_BRUTE 2>/dev/null
    sudo iptables -X MYSQL_BRUTE 2>/dev/null
    if [ "$HAS_IP6" -eq 1 ]; then
        sudo ip6tables -D INPUT -p tcp --dport 3306 -j DROP 2>/dev/null
        sudo ip6tables -F MYSQL_BRUTE 2>/dev/null
        sudo ip6tables -X MYSQL_BRUTE 2>/dev/null
    fi

    # 1. Allow established connections (first)
    sudo iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        sudo iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    if [ "$HAS_IP6" -eq 1 ]; then
        sudo ip6tables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            sudo ip6tables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    fi

    # 2. Always allow localhost
    sudo iptables -A INPUT -p tcp --dport 3306 -s 127.0.0.1 -j ACCEPT
    [ "$HAS_IP6" -eq 1 ] && sudo ip6tables -A INPUT -p tcp --dport 3306 -s ::1 -j ACCEPT

    # 3. Create brute-force protection chain (separate recent list per family)
    sudo iptables -N MYSQL_BRUTE 2>/dev/null
    sudo iptables -F MYSQL_BRUTE
    sudo iptables -A MYSQL_BRUTE -m recent --name mysqlbf --rttl --update --seconds 60 --hitcount 3 -j DROP
    sudo iptables -A MYSQL_BRUTE -m recent --name mysqlbf --set -j ACCEPT
    if [ "$HAS_IP6" -eq 1 ]; then
        sudo ip6tables -N MYSQL_BRUTE 2>/dev/null
        sudo ip6tables -F MYSQL_BRUTE
        sudo ip6tables -A MYSQL_BRUTE -m recent --name mysqlbf6 --rttl --update --seconds 60 --hitcount 3 -j DROP
        sudo ip6tables -A MYSQL_BRUTE -m recent --name mysqlbf6 --set -j ACCEPT
    fi

    # 4. Authorize additional IPs
    echo ""
    echo "Enter IPs to authorize for MySQL access (IPv4 or IPv6, one per line)."
    echo "Press Enter with empty input to finish."
    while true; do
        read -p "  Authorize IP: " AUTH_IP
        [ -z "$AUTH_IP" ] && break
        # Validate IP format (basic) and route to the matching firewall family
        if [[ "$AUTH_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            sudo iptables -A INPUT -p tcp --dport 3306 -s "$AUTH_IP" -j ACCEPT
            echo "  -> $AUTH_IP authorized (IPv4)"
        elif [[ "$AUTH_IP" == *:* ]]; then
            if [ "$HAS_IP6" -eq 1 ]; then
                sudo ip6tables -A INPUT -p tcp --dport 3306 -s "$AUTH_IP" -j ACCEPT
                echo "  -> $AUTH_IP authorized (IPv6)"
            else
                echo "  -> IPv6 firewall unavailable on this host; skipped $AUTH_IP"
            fi
        else
            echo "  -> Invalid IP format: $AUTH_IP (use x.x.x.x, x.x.x.x/xx or an IPv6 address)"
        fi
    done

    # 5. Route new connections through brute-force check
    sudo iptables -A INPUT -p tcp --dport 3306 --syn -j MYSQL_BRUTE
    [ "$HAS_IP6" -eq 1 ] && sudo ip6tables -A INPUT -p tcp --dport 3306 --syn -j MYSQL_BRUTE

    # 6. Drop everything else (last rule)
    sudo iptables -A INPUT -p tcp --dport 3306 -j DROP
    [ "$HAS_IP6" -eq 1 ] && sudo ip6tables -A INPUT -p tcp --dport 3306 -j DROP

    # Save (both families)
    if ! sudo netfilter-persistent save 2>/dev/null; then
        sudo mkdir -p /etc/iptables
        sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
        [ "$HAS_IP6" -eq 1 ] && sudo ip6tables-save | sudo tee /etc/iptables/rules.v6 >/dev/null
    fi

    echo ""
    echo "MySQL firewall rules applied (IPv4):"
    sudo iptables -L INPUT -n --line-numbers | grep -E "3306|MYSQL"
    if [ "$HAS_IP6" -eq 1 ]; then
        echo ""
        echo "MySQL firewall rules applied (IPv6):"
        sudo ip6tables -L INPUT -n --line-numbers | grep -E "3306|MYSQL"
    fi
    echo ""
    echo "--- MySQL secured ---"
}

# ============================================================
# SECURE SSH (interactive hardening)
# ============================================================

secure_ssh() {
    echo "=========================================="
    echo " SSH HARDENING"
    echo "=========================================="
    echo ""

    # --- 1. Create new user ---
    echo -e "  ${C}[1/7] New SSH User${N}"
    echo ""
    read -p "  $(echo -e "${C}Username to create (or existing): ${N}")" SSH_USER
    if [ -z "$SSH_USER" ]; then
        echo -e "  ${R}ERROR: Username cannot be empty!${N}"
        return 1
    fi

    if id "$SSH_USER" &>/dev/null; then
        echo -e "  ${D}User '$SSH_USER' already exists.${N}"
    else
        echo -e "  ${Y}Creating user '$SSH_USER'...${N}"
        sudo adduser "$SSH_USER"
        if [ $? -ne 0 ]; then
            echo -e "  ${R}ERROR: Failed to create user!${N}"
            return 1
        fi
    fi

    # Add to sudo group
    read -p "  $(echo -e "${C}Add '$SSH_USER' to sudo group? (Y/N): ${N}")" add_sudo
    if [[ "$add_sudo" =~ ^[Yy]$ ]]; then
        sudo usermod -aG sudo "$SSH_USER"
        echo -e "  ${G}Added to sudo group.${N}"
    fi

    # --- 2. SSH Key Setup ---
    echo ""
    echo -e "  ${C}[2/7] SSH Key Authentication${N}"
    echo ""
    echo -e "  ${W}How do you want to setup the SSH key?${N}"
    echo ""
    echo -e "  ${C}1.${N} I already have a key pair (paste public key)"
    echo -e "  ${C}2.${N} Generate a new key pair on this server"
    echo -e "  ${C}3.${N} Skip (setup later)"
    echo ""
    read -p "  $(echo -e "${C}Option [1-3]: ${N}")" key_option

    SSH_HOME=$(eval echo "~$SSH_USER")
    KEY_GENERATED=false

    if [[ "$key_option" == "1" || "$key_option" == "2" ]]; then
        sudo mkdir -p "$SSH_HOME/.ssh"
        sudo chmod 700 "$SSH_HOME/.ssh"
        sudo touch "$SSH_HOME/.ssh/authorized_keys"
        sudo chmod 600 "$SSH_HOME/.ssh/authorized_keys"
        sudo chown -R "$SSH_USER:$SSH_USER" "$SSH_HOME/.ssh"
    fi

    if [[ "$key_option" == "1" ]]; then
        # Paste existing public key
        echo ""
        echo -e "  ${Y}Paste your public key below.${N}"
        echo -e "  ${D}(generated with PuttyGen or ssh-keygen)${N}"
        echo ""
        echo -e "  ${Y}NOTE: Large keys (8192 bit) may not paste correctly in terminal.${N}"
        echo -e "  ${Y}If the key is too long, you have two alternatives:${N}"
        echo -e "  ${W}  1.${N} ${D}Type a path to a public key file on this server${N}"
        echo -e "  ${W}  2.${N} ${D}Upload via SFTP to: ${SSH_HOME}/.ssh/authorized_keys${N}"
        echo ""
        read -p "  $(echo -e "${C}Public key or file path: ${N}")" PUB_KEY_INPUT
        if [ -n "$PUB_KEY_INPUT" ]; then
            # Check if input is a file path
            if [ -f "$PUB_KEY_INPUT" ]; then
                PUB_KEY=$(cat "$PUB_KEY_INPUT")
                echo -e "  ${D}Reading key from file: $PUB_KEY_INPUT${N}"
            else
                PUB_KEY="$PUB_KEY_INPUT"
            fi

            # Validate public key format
            KEY_VALID=false
            if echo "$PUB_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2|ssh-dss) [A-Za-z0-9+/=]+ "; then
                KEY_VALID=true
            elif echo "$PUB_KEY" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2|ssh-dss) [A-Za-z0-9+/=]+$"; then
                KEY_VALID=true
            fi

            if [ "$KEY_VALID" == "true" ]; then
                # Check key length (detect truncation)
                KEY_B64=$(echo "$PUB_KEY" | awk '{print $2}')
                KEY_BYTES=$(echo "$KEY_B64" | base64 -d 2>/dev/null | wc -c)
                echo -e "  ${D}Key type: $(echo "$PUB_KEY" | awk '{print $1}')${N}"
                echo -e "  ${D}Key size: ~$((KEY_BYTES * 8)) bits (${KEY_BYTES} bytes)${N}"

                # Warning if key seems truncated (RSA 4096 = ~550 bytes, 8192 = ~1050 bytes)
                if echo "$PUB_KEY" | grep -q "^ssh-rsa" && [ "$KEY_BYTES" -lt 200 ] 2>/dev/null; then
                    echo ""
                    echo -e "  ${R}WARNING: This RSA key seems too small (${KEY_BYTES} bytes).${N}"
                    echo -e "  ${R}The key may have been truncated during paste!${N}"
                    echo ""
                    read -p "  $(echo -e "${Y}Continue anyway? (Y/N): ${N}")" trunc_confirm
                    if [[ ! "$trunc_confirm" =~ ^[Yy]$ ]]; then
                        echo -e "  ${D}Key not saved. Try uploading the key file via SFTP instead.${N}"
                        PUB_KEY=""
                    fi
                fi

                if [ -n "$PUB_KEY" ]; then
                    echo "$PUB_KEY" | sudo tee -a "$SSH_HOME/.ssh/authorized_keys" > /dev/null
                    echo -e "  ${G}Key added to authorized_keys.${N}"
                fi
            else
                echo ""
                echo -e "  ${R}WARNING: This does not look like a valid SSH public key!${N}"
                echo -e "  ${D}Expected format: ssh-rsa AAAA... user@host${N}"
                echo -e "  ${D}Got: $(echo "$PUB_KEY" | cut -c1-60)...${N}"
                echo ""
                read -p "  $(echo -e "${Y}Save it anyway? (Y/N): ${N}")" force_save
                if [[ "$force_save" =~ ^[Yy]$ ]]; then
                    echo "$PUB_KEY" | sudo tee -a "$SSH_HOME/.ssh/authorized_keys" > /dev/null
                    echo -e "  ${Y}Key saved (unvalidated).${N}"
                else
                    echo -e "  ${D}Key not saved.${N}"
                fi
            fi
        else
            echo -e "  ${Y}No key provided. Add manually later to: $SSH_HOME/.ssh/authorized_keys${N}"
        fi

    elif [[ "$key_option" == "2" ]]; then
        # Generate key pair on server
        echo ""
        echo -e "  ${W}Select key type:${N}"
        echo -e "  ${C}1.${N} RSA 4096 bit"
        echo -e "  ${C}2.${N} RSA 8192 bit"
        echo -e "  ${C}3.${N} Ed25519 (recommended, fastest)"
        echo ""
        read -p "  $(echo -e "${C}Key type [1-3]: ${N}")" key_type

        KEY_FILE="$SSH_HOME/.ssh/id_xuione"
        case "$key_type" in
            1) sudo ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -C "$SSH_USER@$(hostname)" ;;
            3) sudo ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "$SSH_USER@$(hostname)" ;;
            *) sudo ssh-keygen -t rsa -b 8192 -f "$KEY_FILE" -N "" -C "$SSH_USER@$(hostname)" ;;
        esac

        if [ $? -eq 0 ] && [ -f "${KEY_FILE}.pub" ]; then
            # Add public key to authorized_keys
            sudo cat "${KEY_FILE}.pub" | sudo tee -a "$SSH_HOME/.ssh/authorized_keys" > /dev/null
            sudo chown -R "$SSH_USER:$SSH_USER" "$SSH_HOME/.ssh"
            KEY_GENERATED=true

            echo ""
            echo -e "  ${G}Key pair generated successfully!${N}"
            echo ""
            echo -e "  ${R}╔══════════════════════════════════════════════════╗${N}"
            echo -e "  ${R}║  IMPORTANT: Download your PRIVATE KEY now!       ║${N}"
            echo -e "  ${R}╚══════════════════════════════════════════════════╝${N}"
            echo ""
            echo -e "  ${W}Private key location:${N}"
            echo -e "  ${Y}${KEY_FILE}${N}"
            echo ""
            echo -e "  ${W}Download via SFTP:${N}"
            echo -e "  ${D}sftp ${SSH_USER}@$(hostname -I | awk '{print $1}')${N}"
            echo -e "  ${D}get ${KEY_FILE}${N}"
            echo ""
            echo -e "  ${W}Or via SCP:${N}"
            echo -e "  ${D}scp ${SSH_USER}@$(hostname -I | awk '{print $1}'):${KEY_FILE} ./${N}"
            echo ""
            echo -e "  ${R}After downloading, this key will be DELETED from the server${N}"
            echo -e "  ${R}for security. You will NOT be able to recover it!${N}"
            echo ""

            # Force confirmation of download
            while true; do
                read -p "  $(echo -e "${Y}Have you downloaded the private key? (yes/no): ${N}")" dl_confirm
                if [[ "$dl_confirm" == "yes" ]]; then
                    echo ""
                    read -p "  $(echo -e "${R}Are you SURE? Without this key you will lose SSH access! (yes/no): ${N}")" dl_confirm2
                    if [[ "$dl_confirm2" == "yes" ]]; then
                        # Delete private key from server
                        sudo rm -f "$KEY_FILE"
                        echo -e "  ${G}Private key deleted from server.${N}"
                        echo -e "  ${D}Public key remains in: $SSH_HOME/.ssh/authorized_keys${N}"
                        break
                    fi
                elif [[ "$dl_confirm" == "no" ]]; then
                    echo ""
                    echo -e "  ${Y}Please download the key before continuing.${N}"
                    echo -e "  ${Y}Open another terminal/session and use SFTP or SCP.${N}"
                    echo ""
                fi
            done
        else
            echo -e "  ${R}ERROR: Key generation failed!${N}"
        fi
    else
        echo -e "  ${D}Key setup skipped. Configure manually later.${N}"
    fi

    # --- 3. SSH Port ---
    echo ""
    echo -e "  ${C}[3/7] SSH Port${N}"
    echo ""
    CURRENT_PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')
    [ -z "$CURRENT_PORT" ] && CURRENT_PORT="22"
    echo -e "  ${D}Current SSH port: ${W}${CURRENT_PORT}${N}"
    read -p "  $(echo -e "${C}New SSH port [${CURRENT_PORT}]: ${N}")" SSH_PORT
    [ -z "$SSH_PORT" ] && SSH_PORT="$CURRENT_PORT"

    # --- 4. Authentication settings ---
    echo ""
    echo -e "  ${C}[4/7] Authentication Settings${N}"
    echo ""
    read -p "  $(echo -e "${C}Disable password authentication? (Y/N) [N]: ${N}")" disable_pass
    [[ "$disable_pass" =~ ^[Yy]$ ]] && PASS_AUTH="no" || PASS_AUTH="yes"

    read -p "  $(echo -e "${C}Disable root login? (Y/N) [Y]: ${N}")" disable_root
    [[ "$disable_root" =~ ^[Nn]$ ]] && PERMIT_ROOT="yes" || PERMIT_ROOT="no"

    read -p "  $(echo -e "${C}Max authentication attempts [3]: ${N}")" MAX_AUTH
    [ -z "$MAX_AUTH" ] && MAX_AUTH="3"

    read -p "  $(echo -e "${C}Max sessions per connection [6]: ${N}")" MAX_SESS
    [ -z "$MAX_SESS" ] && MAX_SESS="6"

    # --- 5. AllowUsers ---
    echo ""
    echo -e "  ${C}[5/7] Allowed Users${N}"
    echo ""
    echo -e "  ${D}Only these users will be able to login via SSH.${N}"
    echo -e "  ${D}'$SSH_USER' will be added automatically.${N}"
    echo ""
    ALLOW_USERS="$SSH_USER"
    while true; do
        read -p "  $(echo -e "${C}Additional user to allow (empty to finish): ${N}")" extra_user
        [ -z "$extra_user" ] && break
        ALLOW_USERS="$ALLOW_USERS $extra_user"
    done
    echo -e "  ${D}AllowUsers: ${W}${ALLOW_USERS}${N}"

    # --- 6. Match Address exceptions (root + password from trusted IPs) ---
    echo ""
    echo -e "  ${C}[6/7] Trusted IPs (Match Address)${N}"
    echo ""
    echo -e "  ${D}These IPs will be allowed root login + password auth${N}"
    echo -e "  ${D}even if disabled globally (e.g. VPN, other servers).${N}"
    echo -e "  ${D}127.0.0.1 is always included.${N}"
    echo ""
    MATCH_IPS="127.0.0.1"
    while true; do
        read -p "  $(echo -e "${C}Trusted IP (empty to finish): ${N}")" trusted_ip
        [ -z "$trusted_ip" ] && break
        MATCH_IPS="$MATCH_IPS,$trusted_ip"
    done

    # Build Match AllowUsers (original + root)
    MATCH_ALLOW="$ALLOW_USERS"
    if ! echo "$MATCH_ALLOW" | grep -qw "root"; then
        MATCH_ALLOW="$MATCH_ALLOW root"
    fi

    # --- 7. Keepalive ---
    echo ""
    echo -e "  ${C}[7/7] Connection Keepalive${N}"
    echo ""
    read -p "  $(echo -e "${C}Client alive interval seconds [60]: ${N}")" ALIVE_INT
    [ -z "$ALIVE_INT" ] && ALIVE_INT="60"
    read -p "  $(echo -e "${C}Client alive max count [2]: ${N}")" ALIVE_MAX
    [ -z "$ALIVE_MAX" ] && ALIVE_MAX="2"

    # --- Review and confirm ---
    echo ""
    echo "=========================================="
    echo " SSH CONFIGURATION SUMMARY"
    echo "=========================================="
    echo -e "  ${W}User:${N}               $SSH_USER"
    echo -e "  ${W}Port:${N}               $SSH_PORT"
    echo -e "  ${W}PermitRootLogin:${N}    $PERMIT_ROOT"
    echo -e "  ${W}PasswordAuth:${N}       $PASS_AUTH"
    echo -e "  ${W}PubkeyAuth:${N}         yes"
    echo -e "  ${W}MaxAuthTries:${N}       $MAX_AUTH"
    echo -e "  ${W}MaxSessions:${N}        $MAX_SESS"
    echo -e "  ${W}AllowUsers:${N}         $ALLOW_USERS"
    echo -e "  ${W}Keepalive:${N}          ${ALIVE_INT}s / ${ALIVE_MAX} max"
    echo -e "  ${W}Trusted IPs:${N}        $MATCH_IPS"
    echo -e "  ${W}Match AllowUsers:${N}   $MATCH_ALLOW"
    echo "=========================================="
    echo ""
    echo -e "  ${R}WARNING: Make sure you have another way to access the server${N}"
    echo -e "  ${R}(console/VNC) in case SSH gets locked out!${N}"
    echo ""
    read -p "  $(echo -e "${C}Apply this configuration? (yes/no): ${N}")" CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo -e "  ${D}Cancelled.${N}"
        return 0
    fi

    # --- Backup current config ---
    SSHD_CONF="/etc/ssh/sshd_config"
    BACKUP_FILE="${SSHD_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    sudo cp "$SSHD_CONF" "$BACKUP_FILE"
    echo -e "  ${D}Backup saved: $BACKUP_FILE${N}"

    # --- Write new sshd_config ---
    sudo tee "$SSHD_CONF" > /dev/null << SSHEOF
# SSH Hardened Configuration
# Generated by XUI Multi-Tool on $(date '+%Y-%m-%d %H:%M:%S')
# Backup: $BACKUP_FILE

Port $SSH_PORT
ListenAddress 0.0.0.0
Protocol 2

# Authentication
StrictModes yes
MaxAuthTries $MAX_AUTH
MaxSessions $MAX_SESS
AuthorizedKeysFile .ssh/authorized_keys

PubkeyAuthentication yes
PasswordAuthentication $PASS_AUTH
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes

# Root access
PermitRootLogin $PERMIT_ROOT

# Restrict users
AllowUsers $ALLOW_USERS

# Security
X11Forwarding no
PrintMotd no
Banner /etc/issue.net

# Environment
AcceptEnv LANG LC_*

# SFTP
Subsystem sftp /usr/lib/openssh/sftp-server

# Keepalive
ClientAliveInterval $ALIVE_INT
ClientAliveCountMax $ALIVE_MAX

# Trusted IPs - allow root + password from these addresses
Match Address $MATCH_IPS
    PermitRootLogin yes
    PubkeyAuthentication no
    PasswordAuthentication yes
    AllowUsers $MATCH_ALLOW
SSHEOF

    echo -e "  ${G}sshd_config written.${N}"

    # --- Test config before restarting ---
    echo ""
    echo -e "  ${D}Testing SSH configuration...${N}"
    if sudo sshd -t 2>&1; then
        echo -e "  ${G}Configuration test: OK${N}"
        echo ""

        # Detect service name: 'ssh' on Ubuntu 22/24, 'sshd' on older/other distros
        if systemctl list-units --type=service --all | grep -q "ssh.service"; then
            SSH_SVC="ssh"
        else
            SSH_SVC="sshd"
        fi

        # Handle socket activation (Ubuntu 22.04+)
        # ssh.socket overrides the Port in sshd_config, must be disabled for custom ports
        if systemctl is-active "${SSH_SVC}.socket" &>/dev/null 2>&1; then
            echo -e "  ${D}Disabling SSH socket activation (required for custom port)...${N}"
            sudo systemctl disable "${SSH_SVC}.socket" 2>/dev/null
            sudo systemctl stop "${SSH_SVC}.socket" 2>/dev/null

            # Override socket if systemd drop-in is needed
            if [ "$SSH_PORT" != "22" ]; then
                sudo mkdir -p /etc/systemd/system/${SSH_SVC}.socket.d
                sudo tee /etc/systemd/system/${SSH_SVC}.socket.d/override.conf > /dev/null << SOCKEOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
SOCKEOF
                sudo systemctl daemon-reload
            fi
        fi

        echo -e "  ${Y}Restarting SSH service...${N}"
        sudo systemctl restart "$SSH_SVC"
        if [ $? -eq 0 ]; then
            # Verify SSH is actually listening on the correct port
            sleep 1
            if sudo ss -tlnp | grep -q ":${SSH_PORT} "; then
                echo -e "  ${G}SSH service restarted successfully (port $SSH_PORT).${N}"
            else
                echo -e "  ${Y}SSH restarted but port $SSH_PORT not detected yet...${N}"
                sleep 2
                if sudo ss -tlnp | grep -q ":${SSH_PORT} "; then
                    echo -e "  ${G}SSH now listening on port $SSH_PORT.${N}"
                else
                    echo -e "  ${R}WARNING: SSH does not appear to be listening on port $SSH_PORT!${N}"
                    echo -e "  ${D}Current SSH ports:${N}"
                    sudo ss -tlnp | grep -i ssh
                fi
            fi
        else
            echo -e "  ${R}WARNING: SSH restart failed! Restoring backup...${N}"
            sudo cp "$BACKUP_FILE" "$SSHD_CONF"
            sudo systemctl restart "$SSH_SVC"
            return 1
        fi
    else
        echo -e "  ${R}Configuration test FAILED! Restoring backup...${N}"
        sudo cp "$BACKUP_FILE" "$SSHD_CONF"
        echo -e "  ${G}Original config restored.${N}"
        return 1
    fi

    # --- Post-restart connection verification ---
    echo ""
    echo -e "  ${R}╔══════════════════════════════════════════════════╗${N}"
    echo -e "  ${R}║  DO NOT close this terminal!                    ║${N}"
    echo -e "  ${R}╚══════════════════════════════════════════════════╝${N}"
    echo ""
    echo -e "  ${Y}Open a NEW terminal and test your SSH connection:${N}"
    echo ""
    echo -e "  ${W}ssh -p $SSH_PORT $SSH_USER@$(hostname -I | awk '{print $1}')${N}"
    echo ""
    if [[ "$PASS_AUTH" == "no" ]]; then
        echo -e "  ${D}Password auth is DISABLED - use your SSH key.${N}"
        echo -e "  ${D}For PuTTY: Connection > SSH > Auth > Private key file${N}"
    fi
    echo ""
    echo -e "  ${C}1.${N} ${G}Connection successful - keep new config${N}"
    echo -e "  ${C}2.${N} ${R}Connection failed - ROLLBACK to previous config${N}"
    echo ""

    while true; do
        read -p "  $(echo -e "${C}Option [1-2]: ${N}")" verify_opt
        case "$verify_opt" in
            1)
                echo ""
                echo "=========================================="
                echo -e "  ${G}SSH HARDENING COMPLETE${N}"
                echo "=========================================="
                echo -e "  ${W}Connect with:${N} ssh -p $SSH_PORT $SSH_USER@$(hostname -I | awk '{print $1}')"
                if [[ "$PASS_AUTH" == "no" ]]; then
                    echo -e "  ${Y}Password auth is DISABLED - use your SSH key!${N}"
                fi
                echo -e "  ${D}Backup: $BACKUP_FILE${N}"
                echo ""
                break
                ;;
            2)
                echo ""
                echo -e "  ${Y}Rolling back to previous SSH configuration...${N}"
                sudo cp "$BACKUP_FILE" "$SSHD_CONF"
                # Restore socket activation if it was disabled
                if [ -d "/etc/systemd/system/${SSH_SVC}.socket.d" ]; then
                    sudo rm -rf "/etc/systemd/system/${SSH_SVC}.socket.d"
                    sudo systemctl daemon-reload
                    sudo systemctl enable "${SSH_SVC}.socket" 2>/dev/null
                    sudo systemctl start "${SSH_SVC}.socket" 2>/dev/null
                fi
                sudo systemctl restart "$SSH_SVC"
                if [ $? -eq 0 ]; then
                    echo -e "  ${G}Previous SSH configuration restored successfully.${N}"
                    echo -e "  ${D}Restored from: $BACKUP_FILE${N}"
                else
                    echo -e "  ${R}WARNING: Failed to restart SSH with old config!${N}"
                    echo -e "  ${R}You may need to access via console/VNC.${N}"
                fi
                echo ""
                break
                ;;
            *)
                echo -e "  ${D}Please choose 1 or 2.${N}"
                ;;
        esac
    done
}

# ============================================================
# RECOMPILE NGINX (fixed directory naming)
# ============================================================

recompile_nginx() {
    if ! check_xui_installed; then return; fi

    NGINX_BIN="/home/xui/bin/nginx/sbin/nginx"
    NGINX_RTMP_BIN="/home/xui/bin/nginx_rtmp/sbin/nginx_rtmp"

    if [ ! -f "$NGINX_BIN" ]; then
        echo "ERROR: nginx binary not found at $NGINX_BIN"
        return 1
    fi

    CURRENT_VER=$($NGINX_BIN -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
    echo "Current nginx version: $CURRENT_VER"

    # Get latest stable release tag from GitHub
    LATEST_TAG=$(curl -s https://api.github.com/repos/nginx/nginx/tags | \
        grep '"name"' | sed 's/.*"name": "\(.*\)",/\1/' | grep "^release-" | head -n 1)
    LATEST_VER=$(echo "$LATEST_TAG" | sed 's/release-//')

    # Guard: GitHub API can be unreachable or rate-limited. Don't proceed to build
    # an empty "nginx-" tag - let the user supply a tag manually or abort.
    if [ -z "$LATEST_TAG" ]; then
        echo "WARNING: Could not fetch the nginx release list from GitHub"
        echo "         (API unreachable or rate-limited)."
        read -p "Enter an nginx release tag to build (e.g. release-1.28.0), empty to abort: " MANUAL_TAG
        if [ -z "$MANUAL_TAG" ]; then
            echo "Aborted."
            return 1
        fi
        LATEST_TAG="$MANUAL_TAG"
    else
        echo "Latest available:      $LATEST_VER (tag: $LATEST_TAG)"
    fi

    # Let the user pin a specific stable tag instead of being forced onto the latest.
    echo ""
    read -p "Release tag to build [$LATEST_TAG] (Enter to accept): " CHOSEN_TAG
    [ -n "$CHOSEN_TAG" ] && LATEST_TAG="$CHOSEN_TAG"
    # Accept either a bare version (1.28.0) or a full tag (release-1.28.0)
    case "$LATEST_TAG" in
        release-*) ;;
        *) LATEST_TAG="release-$LATEST_TAG" ;;
    esac
    LATEST_VER=$(echo "$LATEST_TAG" | sed 's/release-//')

    echo ""
    echo "Will build: $LATEST_TAG  (current: $CURRENT_VER)"
    read -p "Proceed with recompilation? (y/n): " PROCEED
    [[ "$PROCEED" != "y" ]] && return

    # Check free space in /tmp before building. A failed/half build that leaves the
    # service stopped is far worse than refusing up front. Sources + objects for
    # nginx + OpenSSL + PCRE + zlib need roughly 2.5 GB.
    TMP_AVAIL_KB=$(df -Pk /tmp 2>/dev/null | awk 'NR==2{print $4}')
    REQUIRED_KB=$((2500 * 1024))
    if [ -n "$TMP_AVAIL_KB" ] && [ "$TMP_AVAIL_KB" -lt "$REQUIRED_KB" ] 2>/dev/null; then
        echo "ERROR: Not enough free space in /tmp for the build."
        echo "       Available: $((TMP_AVAIL_KB / 1024)) MB, need ~2500 MB."
        echo "       Free up space and retry (XUI service was NOT stopped)."
        return 1
    fi

    OPENSSL_VERSION="3.3.2"
    PCRE_VERSION="8.45"
    ZLIB_VERSION="1.3.2"
    BUILD_DIR="/tmp/nginx_build_$$"

    mkdir -p "$BUILD_DIR" && cd "$BUILD_DIR"

    echo "Stopping XUI service..."
    sudo systemctl stop xuione 2>/dev/null

    echo "Installing build dependencies..."
    if ! sudo apt-get -y install build-essential git libssl-dev tar unzip curl; then
        echo "ERROR: Failed to install build dependencies. Aborting build."
        sudo systemctl start xuione 2>/dev/null
        return 1
    fi

    # Download sources
    echo "Downloading nginx $LATEST_TAG..."
    curl -L -o nginx.tar.gz "https://github.com/nginx/nginx/archive/refs/tags/$LATEST_TAG.tar.gz"
    tar -xf nginx.tar.gz
    # The extracted directory will be named nginx-$LATEST_TAG (e.g., nginx-release-1.27.3)
    NGINX_SRC_DIR=$(ls -d nginx-* 2>/dev/null | head -1)
    if [ -z "$NGINX_SRC_DIR" ]; then
        echo "ERROR: Failed to extract nginx source!"
        sudo systemctl start xuione 2>/dev/null
        return 1
    fi
    echo "Nginx source dir: $NGINX_SRC_DIR"

    echo "Downloading OpenSSL $OPENSSL_VERSION..."
    wget -q "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
    tar -xf "openssl-$OPENSSL_VERSION.tar.gz"

    echo "Downloading PCRE $PCRE_VERSION..."
    wget -q "https://sourceforge.net/projects/pcre/files/pcre/$PCRE_VERSION/pcre-$PCRE_VERSION.tar.gz/download" -O pcre.tar.gz
    tar -xzf pcre.tar.gz

    echo "Downloading zlib $ZLIB_VERSION..."
    wget -q "https://zlib.net/zlib-$ZLIB_VERSION.tar.gz"
    tar -xzf "zlib-$ZLIB_VERSION.tar.gz"

    echo "Cloning nginx-http-flv-module..."
    git clone --depth 1 https://github.com/winshining/nginx-http-flv-module.git

    # Try to detect current compile flags from existing binary
    echo ""
    echo "Checking current nginx compile flags..."
    CURRENT_FLAGS=$($NGINX_BIN -V 2>&1 | grep "configure arguments:" || echo "")
    echo "$CURRENT_FLAGS"
    echo ""

    # Build main nginx (HTTP) - matching XUI.ONE original compile flags
    echo "=== Building main nginx ==="
    cd "$BUILD_DIR/$NGINX_SRC_DIR"
    ./auto/configure \
        --prefix=/home/xui/bin/nginx \
        --with-compat \
        --with-threads \
        --with-file-aio \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_auth_request_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_sub_module \
        --with-pcre="$BUILD_DIR/pcre-$PCRE_VERSION" \
        --with-pcre-jit \
        --with-zlib="$BUILD_DIR/zlib-$ZLIB_VERSION" \
        --with-openssl="$BUILD_DIR/openssl-$OPENSSL_VERSION" \
        --with-openssl-opt=no-nextprotoneg \
        --with-cc-opt='-O2 -g -pipe -Wall -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic -fPIC' \
        --with-ld-opt='-Wl,-z,relro -Wl,-z,now -pie'

    if ! make -j$(nproc); then
        echo "ERROR: nginx build failed!"
        sudo systemctl start xuione 2>/dev/null
        return 1
    fi

    # Verify the new binary supports the required modules
    echo ""
    echo "Verifying compiled modules..."
    ./objs/nginx -V 2>&1 | grep -oP '--with-\S+' | sort
    echo ""

    # Backup originals
    sudo cp "$NGINX_BIN" "${NGINX_BIN}.bak.$(date +%Y%m%d%H%M%S)"
    sudo cp ./objs/nginx "$NGINX_BIN"
    echo "Main nginx updated."

    # Build RTMP nginx - same modules plus nginx-http-flv-module
    echo ""
    echo "=== Building RTMP nginx ==="
    make clean
    ./auto/configure \
        --prefix=/home/xui/bin/nginx_rtmp \
        --add-module="$BUILD_DIR/nginx-http-flv-module" \
        --with-compat \
        --with-threads \
        --with-file-aio \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_auth_request_module \
        --with-http_stub_status_module \
        --with-http_gzip_static_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_secure_link_module \
        --with-http_slice_module \
        --with-http_sub_module \
        --with-pcre="$BUILD_DIR/pcre-$PCRE_VERSION" \
        --with-pcre-jit \
        --with-zlib="$BUILD_DIR/zlib-$ZLIB_VERSION" \
        --with-openssl="$BUILD_DIR/openssl-$OPENSSL_VERSION" \
        --with-openssl-opt=no-nextprotoneg \
        --with-cc-opt='-O2 -g -pipe -Wall -fexceptions -fstack-protector --param=ssp-buffer-size=4 -m64 -mtune=generic -fPIC' \
        --with-ld-opt='-Wl,-z,relro -Wl,-z,now -pie'

    if ! make -j$(nproc); then
        echo "ERROR: nginx RTMP build failed!"
        sudo systemctl start xuione 2>/dev/null
        return 1
    fi

    if [ -f "$NGINX_RTMP_BIN" ]; then
        sudo cp "$NGINX_RTMP_BIN" "${NGINX_RTMP_BIN}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    sudo cp ./objs/nginx "$NGINX_RTMP_BIN"
    echo "RTMP nginx updated."

    # Cleanup
    cd /tmp
    rm -rf "$BUILD_DIR"

    echo "Starting XUI service..."
    sudo systemctl start xuione 2>/dev/null

    # Verify
    NEW_VER=$($NGINX_BIN -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
    echo ""
    echo "Nginx updated: $CURRENT_VER -> $NEW_VER"
}

# ============================================================
# FIX UBUNTU 24.04+ (standalone, for LBs installed before fix)
# ============================================================

fix_ubuntu_24() {
    detect_os
    fix_compatibility
    echo ""
    echo "If you need to install MariaDB $MARIADB_SERIES on this LB, use Installation > Install MariaDB."
}

# ============================================================
# STANDALONE MARIADB INSTALL
# ============================================================

install_mariadb() {
    detect_os
    fix_compatibility
    force_mariadb
}

# ============================================================
# IMPORT DATABASE
# ============================================================

# mariadb-dump (10.6.17+/11.x) prepends a "sandbox mode" header comment whose
# \- token makes the mysql client abort on import. Remove ONLY that exact comment
# line, so any legitimate \- inside data/strings is left untouched.
# Reads stdin, writes stdout (use in a pipe, or with `strip_dump_sandbox < file`).
strip_dump_sandbox() {
    sed '/^\/\*M!999999\\- enable the sandbox mode \*\//d'
}

import_database() {
    echo "=========================================="
    echo " IMPORT DATABASE"
    echo "=========================================="

    # Check if MariaDB is running
    if ! systemctl is-active mariadb &>/dev/null; then
        echo "ERROR: MariaDB is not running!"
        echo "Start it with: sudo systemctl start mariadb"
        return 1
    fi

    # Get MySQL credentials from XUI config if available
    DB_NAME="xui"
    MYSQL_EXTRA=""

    if [ -f "/home/xui/config/config.ini" ]; then
        CFG_HOST=$(grep -oP 'hostname\s*=\s*"\K[^"]+' /home/xui/config/config.ini 2>/dev/null)
        CFG_DB=$(grep -oP 'database\s*=\s*"\K[^"]+' /home/xui/config/config.ini 2>/dev/null)
        [ -n "$CFG_DB" ] && DB_NAME="$CFG_DB"
        echo "XUI config found. Database: $DB_NAME"
    fi

    # Test MySQL root access
    echo ""
    echo "Testing MySQL access..."
    if mysql -u root -e "SELECT 1;" &>/dev/null; then
        echo "MySQL root access: OK (no password)"
    else
        read -rs -p "MySQL root password: " MYSQL_ROOT_PASS
        echo ""
        MYSQL_EXTRA="-p${MYSQL_ROOT_PASS}"
        if ! mysql -u root $MYSQL_EXTRA -e "SELECT 1;" &>/dev/null; then
            echo "ERROR: Cannot access MySQL with provided password!"
            return 1
        fi
        echo "MySQL root access: OK"
    fi

    # Show current database info
    echo ""
    CURRENT_TABLES=$(mysql -u root $MYSQL_EXTRA -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null)
    CURRENT_SIZE=$(mysql -u root $MYSQL_EXTRA -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null)
    echo "Current database '$DB_NAME': ${CURRENT_TABLES:-0} tables, ${CURRENT_SIZE:-0} MB"

    # Ask for the SQL file path or MEGA link
    echo ""
    echo "Supported formats: .sql, .sql.gz"
    echo ""
    echo " 1) Local file (path on this server)"
    echo " 2) Download from MEGA.nz link"
    echo ""
    read -p "Select source [1-2]: " DB_SOURCE

    if [[ "$DB_SOURCE" == "2" ]]; then
        # --- MEGA DOWNLOAD ---
        echo ""
        read -p "Paste MEGA.nz link: " MEGA_LINK

        # Validate MEGA link format
        if [[ ! "$MEGA_LINK" =~ ^https?://(mega\.nz|mega\.co\.nz)/(file|folder|#) ]]; then
            echo "ERROR: Invalid MEGA link format!"
            echo "Expected: https://mega.nz/file/... or https://mega.nz/#!..."
            return 1
        fi

        # Install MEGAcmd (official MEGA client - supports all link formats)
        if ! command -v mega-get &>/dev/null; then
            echo "Installing MEGAcmd..."
            # Detect distro for correct package
            detect_os
            case "$OS_CODENAME" in
                focal)   MEGA_DEB="megacmd-xUbuntu_20.04_amd64.deb" ;;
                jammy)   MEGA_DEB="megacmd-xUbuntu_22.04_amd64.deb" ;;
                noble)   MEGA_DEB="megacmd-xUbuntu_24.04_amd64.deb" ;;
                *)       MEGA_DEB="megacmd-xUbuntu_22.04_amd64.deb" ;;  # fallback
            esac
            cd /tmp
            wget -q "https://mega.nz/linux/repo/xUbuntu_${OS_VERSION}/amd64/${MEGA_DEB}" -O megacmd.deb 2>/dev/null
            if [ -f megacmd.deb ] && [ -s megacmd.deb ]; then
                sudo dpkg -i megacmd.deb 2>/dev/null
                sudo apt-get install -f -y 2>/dev/null  # fix dependencies
                rm -f megacmd.deb
            fi
            # Fallback: try megatools if MEGAcmd failed
            if ! command -v mega-get &>/dev/null; then
                echo "  -> MEGAcmd not available, trying megatools..."
                sudo apt-get install -y megatools 2>/dev/null
                if ! command -v megadl &>/dev/null; then
                    echo "ERROR: Could not install MEGA download tools!"
                    echo "Install manually: https://mega.io/cmd"
                    return 1
                fi
            fi
        fi

        # Download from MEGA
        MEGA_DOWNLOAD_DIR="/tmp/mega_db_$$"
        mkdir -p "$MEGA_DOWNLOAD_DIR"
        echo ""
        echo "Downloading from MEGA..."

        MEGA_DL_OK=false
        if command -v mega-get &>/dev/null; then
            # MEGAcmd: supports all link formats (mega.nz/file/... and mega.nz/#!...)
            mega-get "$MEGA_LINK" "$MEGA_DOWNLOAD_DIR/" && MEGA_DL_OK=true
        elif command -v megadl &>/dev/null; then
            # megatools fallback: may not support new link format
            megadl --path "$MEGA_DOWNLOAD_DIR" "$MEGA_LINK" && MEGA_DL_OK=true
        fi

        if [ "$MEGA_DL_OK" != "true" ]; then
            echo "ERROR: MEGA download failed!"
            rm -rf "$MEGA_DOWNLOAD_DIR"
            return 1
        fi

        # Find the downloaded file
        DB_FILE=$(find "$MEGA_DOWNLOAD_DIR" -type f \( -name "*.sql" -o -name "*.sql.gz" \) | head -1)
        if [ -z "$DB_FILE" ]; then
            # Check if any file was downloaded at all
            DOWNLOADED=$(find "$MEGA_DOWNLOAD_DIR" -type f | head -1)
            if [ -z "$DOWNLOADED" ]; then
                echo "ERROR: No files were downloaded!"
                rm -rf "$MEGA_DOWNLOAD_DIR"
                return 1
            fi
            # Check if the downloaded file is a valid format even without proper extension
            if file "$DOWNLOADED" | grep -q "gzip"; then
                DB_FILE="$DOWNLOADED"
                echo "Downloaded file detected as gzip compressed."
            elif file "$DOWNLOADED" | grep -qi "text\|ascii"; then
                # Peek inside to check if it looks like SQL
                if head -5 "$DOWNLOADED" | grep -qiE "^(--|CREATE|INSERT|DROP|SET|/\*)" ; then
                    DB_FILE="$DOWNLOADED"
                    echo "Downloaded file detected as SQL."
                else
                    echo "ERROR: Downloaded file does not appear to be a SQL database!"
                    echo "File type: $(file "$DOWNLOADED")"
                    echo "First lines:"
                    head -3 "$DOWNLOADED"
                    rm -rf "$MEGA_DOWNLOAD_DIR"
                    return 1
                fi
            else
                echo "ERROR: Downloaded file is not a supported format (.sql or .sql.gz)!"
                echo "File: $(basename "$DOWNLOADED")"
                echo "Type: $(file "$DOWNLOADED")"
                rm -rf "$MEGA_DOWNLOAD_DIR"
                return 1
            fi
        fi
        MEGA_CLEANUP="$MEGA_DOWNLOAD_DIR"
        echo "Downloaded: $(basename "$DB_FILE")"

    else
        # --- LOCAL FILE ---
        echo ""
        read -p "Path to database file: " DB_FILE

        # Expand ~ if used
        DB_FILE="${DB_FILE/#\~/$HOME}"

        # Remove quotes if the user pasted a path with quotes
        DB_FILE=$(echo "$DB_FILE" | sed "s/^['\"]//;s/['\"]$//")

        if [ ! -f "$DB_FILE" ]; then
            echo "ERROR: File not found: $DB_FILE"
            return 1
        fi
        MEGA_CLEANUP=""
    fi

    # Detect format and validate
    FILE_SIZE=$(du -h "$DB_FILE" | cut -f1)
    echo ""
    if [[ "$DB_FILE" == *.sql.gz ]] || file "$DB_FILE" | grep -q "gzip"; then
        FILE_TYPE="gzip"
        # Validate: try to peek inside the gzip to confirm it's SQL
        PEEK=$(gunzip -c "$DB_FILE" 2>/dev/null | head -5)
        if echo "$PEEK" | grep -qiE "^(--|CREATE|INSERT|DROP|SET|/\*)" ; then
            echo "File: $(basename "$DB_FILE") ($FILE_SIZE, compressed SQL) - VALID"
        else
            echo "WARNING: File is gzip but content doesn't look like SQL!"
            echo "First lines of content:"
            echo "$PEEK" | head -3
            echo ""
            read -p "Continue anyway? (y/n): " FORCE_CONTINUE
            if [[ "$FORCE_CONTINUE" != "y" ]]; then
                [ -n "$MEGA_CLEANUP" ] && rm -rf "$MEGA_CLEANUP"
                return 0
            fi
        fi
    elif [[ "$DB_FILE" == *.sql ]]; then
        FILE_TYPE="sql"
        # Validate: check first lines look like SQL
        PEEK=$(head -5 "$DB_FILE")
        if echo "$PEEK" | grep -qiE "^(--|CREATE|INSERT|DROP|SET|/\*)" ; then
            echo "File: $(basename "$DB_FILE") ($FILE_SIZE, SQL) - VALID"
        else
            echo "WARNING: File doesn't look like a SQL dump!"
            echo "First lines:"
            echo "$PEEK" | head -3
            echo ""
            read -p "Continue anyway? (y/n): " FORCE_CONTINUE
            if [[ "$FORCE_CONTINUE" != "y" ]]; then
                [ -n "$MEGA_CLEANUP" ] && rm -rf "$MEGA_CLEANUP"
                return 0
            fi
        fi
    else
        # Unknown extension, detect by content
        if file "$DB_FILE" | grep -q "gzip"; then
            FILE_TYPE="gzip"
            echo "File: $(basename "$DB_FILE") ($FILE_SIZE, detected as gzip)"
        else
            FILE_TYPE="sql"
            echo "File: $(basename "$DB_FILE") ($FILE_SIZE, assuming SQL)"
        fi
    fi

    # Confirm
    echo ""
    echo "=========================================="
    echo " IMPORT SUMMARY"
    echo "=========================================="
    echo " Source:   $(basename "$DB_FILE")"
    echo " Size:     $FILE_SIZE"
    echo " Format:   $FILE_TYPE"
    echo " Target:   $DB_NAME"
    echo " Current:  ${CURRENT_TABLES:-0} tables, ${CURRENT_SIZE:-0} MB"
    echo "=========================================="
    echo ""
    echo "WARNING: This will DROP the existing '$DB_NAME' database"
    echo "         and replace it with the contents of this file!"
    echo ""
    read -p "Are you sure? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Cancelled."
        [ -n "$MEGA_CLEANUP" ] && rm -rf "$MEGA_CLEANUP"
        return 0
    fi

    # Stop XUI service before import
    echo ""
    echo "Stopping XUI service..."
    sudo systemctl stop xuione 2>/dev/null

    # Backup current database first
    echo "Backing up current database..."
    BACKUP_FILE="/tmp/xui_backup_$(date +%Y%m%d_%H%M%S).sql.gz"
    mysqldump -u root $MYSQL_EXTRA "$DB_NAME" 2>/dev/null | gzip > "$BACKUP_FILE"
    if [ -s "$BACKUP_FILE" ]; then
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        echo "Backup saved: $BACKUP_FILE ($BACKUP_SIZE)"
    else
        echo "WARNING: Backup may be empty (new install?). Continuing..."
    fi

    # Drop and recreate database
    echo ""
    echo "Recreating database '$DB_NAME'..."
    mysql -u root $MYSQL_EXTRA -e "DROP DATABASE IF EXISTS $DB_NAME; CREATE DATABASE $DB_NAME;" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to recreate database!"
        sudo systemctl start xuione 2>/dev/null
        return 1
    fi

    # Import
    # Pre-import: count tables in source file for later comparison
    echo "Analyzing source file..."
    if [[ "$FILE_TYPE" == "gzip" ]]; then
        SRC_TABLES=$(gunzip -c "$DB_FILE" | grep -c "^CREATE TABLE" 2>/dev/null)
    else
        SRC_TABLES=$(grep -c "^CREATE TABLE" "$DB_FILE" 2>/dev/null)
    fi
    echo "Source file contains $SRC_TABLES tables"
    echo ""
    echo "Importing database... (this may take a while)"
    IMPORT_START=$(date +%s)

    # Strip the mariadb-dump "sandbox mode" header comment (see strip_dump_sandbox)
    # before piping to the mysql client. We remove only that one comment line, not
    # every \- in the file, so real data is preserved.
    if [[ "$FILE_TYPE" == "gzip" ]]; then
        if command -v pv &>/dev/null; then
            pv "$DB_FILE" | gunzip | strip_dump_sandbox | mysql -u root $MYSQL_EXTRA "$DB_NAME"
        else
            gunzip -c "$DB_FILE" | strip_dump_sandbox | mysql -u root $MYSQL_EXTRA "$DB_NAME"
        fi
    else
        if command -v pv &>/dev/null; then
            pv "$DB_FILE" | strip_dump_sandbox | mysql -u root $MYSQL_EXTRA "$DB_NAME"
        else
            strip_dump_sandbox < "$DB_FILE" | mysql -u root $MYSQL_EXTRA "$DB_NAME"
        fi
    fi

    IMPORT_RESULT=$?
    IMPORT_END=$(date +%s)
    IMPORT_DURATION=$((IMPORT_END - IMPORT_START))

    if [ $IMPORT_RESULT -ne 0 ]; then
        echo ""
        echo "ERROR: Import failed!"
        echo "Restoring backup..."
        gunzip -c "$BACKUP_FILE" | strip_dump_sandbox | mysql -u root $MYSQL_EXTRA "$DB_NAME" 2>/dev/null
        sudo systemctl start xuione 2>/dev/null
        [ -n "$MEGA_CLEANUP" ] && rm -rf "$MEGA_CLEANUP"
        return 1
    fi

    # Show result
    echo ""
    NEW_TABLES=$(mysql -u root $MYSQL_EXTRA -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null)
    NEW_SIZE=$(mysql -u root $MYSQL_EXTRA -N -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) FROM information_schema.tables WHERE table_schema='$DB_NAME';" 2>/dev/null)

    echo "=========================================="
    echo " IMPORT COMPLETE"
    echo "=========================================="
    echo " Duration:  ${IMPORT_DURATION}s"
    echo " Tables:    $NEW_TABLES"
    echo " Size:      ${NEW_SIZE} MB"
    echo " Backup:    $BACKUP_FILE"
    echo "=========================================="

    # ---- VERIFICATION ----
    echo ""
    echo "--- Verifying database integrity ---"

    # 1. Table count comparison (source file vs database)
    echo ""
    if [ -n "$SRC_TABLES" ] && [ "$SRC_TABLES" -gt 0 ] 2>/dev/null; then
        if [ "$SRC_TABLES" -eq "$NEW_TABLES" ]; then
            echo "Table count:  $NEW_TABLES/$SRC_TABLES - MATCH"
        else
            echo "Table count:  $NEW_TABLES/$SRC_TABLES - MISMATCH!"
            echo "  WARNING: Source file had $SRC_TABLES tables but database has $NEW_TABLES"
        fi
    fi

    # 2. Key record counts
    echo ""
    echo "Record counts:"
    mysql -u root $MYSQL_EXTRA -e "
        SELECT 'streams' AS item, COUNT(*) AS count FROM \`$DB_NAME\`.\`streams\`
        UNION ALL SELECT 'bouquets', COUNT(*) FROM \`$DB_NAME\`.\`bouquets\`
        UNION ALL SELECT 'lines', COUNT(*) FROM \`$DB_NAME\`.\`lines\`
        UNION ALL SELECT 'users', COUNT(*) FROM \`$DB_NAME\`.\`users\`
        UNION ALL SELECT 'servers', COUNT(*) FROM \`$DB_NAME\`.\`servers\`
        UNION ALL SELECT 'epg', COUNT(*) FROM \`$DB_NAME\`.\`epg\`;" 2>/dev/null

    # 3. Table integrity check (mysqlcheck)
    echo ""
    echo "Checking table integrity..."
    CHECK_RESULT=$(mysqlcheck -u root $MYSQL_EXTRA --check "$DB_NAME" 2>/dev/null)
    CORRUPT_COUNT=$(echo "$CHECK_RESULT" | grep -cv "OK$")
    if [ "$CORRUPT_COUNT" -eq 0 ]; then
        echo "All $NEW_TABLES tables: OK"
    else
        echo "$CHECK_RESULT" | grep -v "OK$"
        echo ""
        echo "WARNING: $CORRUPT_COUNT table(s) may have issues. Running repair..."
        mysqlcheck -u root $MYSQL_EXTRA --repair "$DB_NAME" 2>/dev/null
    fi

    # 4. Re-export and compare with source (row count per table)
    echo ""
    echo "Comparing row counts with source file..."
    # Extract row counts from source file (count INSERT value groups per table)
    if [[ "$FILE_TYPE" == "gzip" ]]; then
        SRC_ROW_DATA=$(gunzip -c "$DB_FILE" | grep "^INSERT INTO" | sed "s/^INSERT INTO \`\([^\`]*\)\`.*/\1/" | sort | uniq -c | sort -rn | head -10)
    else
        SRC_ROW_DATA=$(grep "^INSERT INTO" "$DB_FILE" | sed "s/^INSERT INTO \`\([^\`]*\)\`.*/\1/" | sort | uniq -c | sort -rn | head -10)
    fi
    # Get row counts from database for the same tables
    DB_ROW_DATA=$(mysql -u root $MYSQL_EXTRA -N -e "
        SELECT table_name, table_rows
        FROM information_schema.tables
        WHERE table_schema='$DB_NAME'
        ORDER BY table_rows DESC LIMIT 10;" 2>/dev/null)

    echo ""
    echo "Top tables by size (database):"
    mysql -u root $MYSQL_EXTRA -e "
        SELECT table_name AS 'Table',
               table_rows AS 'Rows',
               ROUND((data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
        FROM information_schema.tables
        WHERE table_schema='$DB_NAME'
        ORDER BY (data_length + index_length) DESC
        LIMIT 10;" 2>/dev/null

    echo ""
    echo "--- Verification complete ---"

    # Run access tool to sync permissions
    echo ""
    echo "Syncing access permissions..."
    sudo /home/xui/tools access 2>/dev/null

    # Restart XUI
    echo ""
    echo "Starting XUI service..."
    sudo systemctl start xuione 2>/dev/null
    sleep 3

    if systemctl is-active xuione &>/dev/null; then
        echo "XUI service: RUNNING"
    else
        echo "WARNING: XUI service did not start. Check logs with: journalctl -u xuione -n 50"
    fi

    # Cleanup MEGA temp files
    [ -n "$MEGA_CLEANUP" ] && rm -rf "$MEGA_CLEANUP"
}

# ============================================================
# FIX TOOLS (ported from the xui_monitor bot's FIXES menu)
# ------------------------------------------------------------
# The bot ran each fix over SSH across every server; here each runs LOCALLY on
# the server this script is executed on. Every fix briefs the operator first and
# asks for confirmation - nothing runs on selection alone.
# ============================================================

# Mini-briefing + confirmation. Returns 0 to proceed, non-zero to cancel.
fix_brief() {
    local title="$1" what="$2" why="$3" risk="$4" revert="$5"
    echo ""
    echo -e "  ${W}[FIX] ${title}${N}"
    echo -e "  ${D}--------------------------------------------------${N}"
    echo -e "  ${C}What:${N}   $what"
    echo -e "  ${C}Why:${N}    $why"
    echo -e "  ${C}Risk:${N}   $risk"
    echo -e "  ${C}Revert:${N} $revert"
    echo ""
    read -p "  $(echo -e "${Y}Proceed? (y/N): ${N}")" _confirm
    [[ "$_confirm" =~ ^[Yy]$ ]]
}

# --- FIX: prefer IPv4 (/etc/gai.conf) ---
fix_ipv6_pref() {
    local GAI="/etc/gai.conf"
    local MARK="xui-multi-tool fix_ipv6_pref"

    # Already applied -> offer to revert instead.
    if grep -v '^#' "$GAI" 2>/dev/null | grep -qF 'precedence ::ffff:0:0/96'; then
        echo ""
        echo -e "  ${D}IPv4-preference rule already present in $GAI.${N}"
        read -p "  $(echo -e "${Y}Remove it (revert)? (y/N): ${N}")" r
        if [[ "$r" =~ ^[Yy]$ ]]; then
            sudo cp -p "$GAI" "${GAI}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
            sudo sed -i "/$MARK/d; \#precedence ::ffff:0:0/96#d" "$GAI"
            echo "  -> Reverted. System default address selection restored."
        fi
        return
    fi

    fix_brief "Prefer IPv4 (gai.conf)" \
        "Appends a rule to /etc/gai.conf so the system prefers IPv4 when a host has both A and AAAA." \
        "On hosts with broken/unrouted IPv6, outbound connections (Let's Encrypt, apt, APIs) hang on IPv6 first." \
        "Very low - one line appended; a timestamped backup is saved." \
        "Yes - re-run this option to remove the rule." || { echo "  Cancelled."; return; }

    sudo cp -p "$GAI" "${GAI}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    {
        echo ""
        echo "# Prefer IPv4 (IPv6 without route) - $MARK"
        echo "precedence ::ffff:0:0/96  100"
    } | sudo tee -a "$GAI" >/dev/null
    echo "  -> Applied."
    python3 -c "import socket; i=socket.getaddrinfo('acme-v02.api.letsencrypt.org',443,0,socket.SOCK_STREAM); print('  -> Resolver now picks:', 'IPv4' if i[0][0]==socket.AF_INET else 'IPv6')" 2>/dev/null || true
}

# --- FIX: disable apport (crash reporter) ---
fix_apport() {
    fix_brief "Disable apport (crash reporter)" \
        "Stops the apport service, disables it at boot, and sets enabled=0 in /etc/default/apport." \
        "apport wakes on crashes to write dumps - wasted CPU/disk on a streaming host that never uses them." \
        "Low - only a crash reporter is turned off." \
        "By hand: set enabled=1 in /etc/default/apport and 'systemctl enable --now apport'." || { echo "  Cancelled."; return; }

    sudo systemctl stop apport 2>/dev/null
    sudo systemctl disable apport 2>/dev/null
    [ -f /etc/default/apport ] && sudo sed -i 's/^enabled=1/enabled=0/' /etc/default/apport
    local svc
    svc=$(systemctl is-active apport 2>/dev/null || echo inactive)
    if [ "$svc" != "active" ]; then
        echo "  -> apport disabled (service: $svc)."
    else
        echo "  -> WARNING: apport is still active."
    fi
}

# --- FIX: time sync (timezone + chrony/NTP) ---
fix_timesync() {
    fix_brief "Time sync (timezone + chrony/NTP)" \
        "Sets the timezone, installs chrony, points it at an NTP pool, and enables clock synchronisation." \
        "A drifting clock breaks TLS handshakes, EPG timing, line-expiry maths and log correlation." \
        "Low - installs chrony and rewrites its pool/server lines (chrony.conf backed up first)." \
        "By hand: restore the chrony.conf.bak.* backup." || { echo "  Cancelled."; return; }

    local TZ POOL
    read -p "  Timezone [UTC]: " TZ;  [ -z "$TZ" ] && TZ="UTC"
    read -p "  NTP pool [pool.ntp.org]: " POOL; [ -z "$POOL" ] && POOL="pool.ntp.org"

    sudo timedatectl set-timezone "$TZ" 2>/dev/null
    sudo apt-get install -y chrony 2>/dev/null
    local CC="/etc/chrony/chrony.conf"
    [ ! -f "$CC" ] && CC="/etc/chrony.conf"
    if [ -f "$CC" ]; then
        sudo cp -p "$CC" "${CC}.bak.$(date +%Y%m%d%H%M%S)"
        sudo sed -i '/^pool /d; /^server /d' "$CC"
        echo "pool $POOL iburst" | sudo tee -a "$CC" >/dev/null
    fi
    sudo timedatectl set-ntp on 2>/dev/null
    sudo systemctl enable --now chrony 2>/dev/null
    sudo chronyc makestep 2>/dev/null
    echo "  -> Timezone: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"
    echo "  -> NTP pool: $POOL"

    # XUI-only extra (mirrors the bot's main-server step): ensure the panel's
    # default line-expiry window is sane.
    if check_xui_installed >/dev/null 2>&1; then
        read -p "  $(echo -e "${C}Also set XUI create_expiration=1440 in the DB? (y/N): ${N}")" ce
        if [[ "$ce" =~ ^[Yy]$ ]]; then
            sudo mysql -e "ALTER TABLE xui.settings MODIFY create_expiration INT UNSIGNED NOT NULL DEFAULT 1440;" 2>&1
            sudo mysql -e "UPDATE xui.settings SET create_expiration = 1440;" 2>&1
            echo "  -> create_expiration = $(sudo mysql -N -e 'SELECT create_expiration FROM xui.settings LIMIT 1;' 2>/dev/null || echo '?')"
        fi
    fi
}

# --- FIX: DNS resolvers (static resolv.conf) ---
fix_dns() {
    # Offer revert first if a previous run left a backup.
    if sudo test -f /root/dns_fix_backup/latest 2>/dev/null; then
        echo ""
        echo -e "  ${D}A previous DNS fix backup exists.${N}"
        read -p "  $(echo -e "${Y}Revert to the saved resolv.conf/gai.conf? (y/N): ${N}")" r
        if [[ "$r" =~ ^[Yy]$ ]]; then
            local BKD
            BKD=$(sudo cat /root/dns_fix_backup/latest 2>/dev/null)
            if [ -n "$BKD" ] && sudo test -d "$BKD"; then
                sudo chattr -i /etc/resolv.conf 2>/dev/null
                sudo rm -f /etc/resolv.conf
                if sudo test -f "$BKD/link_target"; then
                    sudo ln -s "$(sudo cat "$BKD/link_target")" /etc/resolv.conf
                else
                    sudo cp -p "$BKD/resolv.conf" /etc/resolv.conf
                fi
                sudo cp -p "$BKD/gai.conf" /etc/gai.conf 2>/dev/null
                sudo systemctl enable --now systemd-resolved 2>/dev/null
                echo "  -> Reverted from $BKD."
            else
                echo "  -> Backup directory missing; cannot revert automatically."
            fi
            return
        fi
    fi

    fix_brief "DNS resolvers (static resolv.conf)" \
        "Backs up DNS, disables systemd-resolved, writes fixed resolvers (1.1.1.1/1.0.0.1/8.8.8.8), optional lock." \
        "The systemd-resolved stub (127.0.0.53) fails/stalls on some hosts, breaking apt/certbot/API lookups." \
        "Medium - replaces /etc/resolv.conf and stops systemd-resolved; full backup under /root/dns_fix_backup." \
        "Yes - re-run this option to restore the saved backup." || { echo "  Cancelled."; return; }

    local DO_LOCK=0
    read -p "  $(echo -e "${C}Lock /etc/resolv.conf so nothing overwrites it (chattr +i)? (y/N): ${N}")" l
    [[ "$l" =~ ^[Yy]$ ]] && DO_LOCK=1

    local BKD="/root/dns_fix_backup/$(date +%Y%m%d%H%M%S)"
    sudo mkdir -p "$BKD"
    [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf | sudo tee "$BKD/link_target" >/dev/null
    sudo cp -pL /etc/resolv.conf "$BKD/resolv.conf" 2>/dev/null
    sudo cp -p /etc/gai.conf "$BKD/gai.conf" 2>/dev/null
    echo "$BKD" | sudo tee /root/dns_fix_backup/latest >/dev/null

    sudo systemctl disable --now systemd-resolved 2>/dev/null
    sudo chattr -i /etc/resolv.conf 2>/dev/null
    sudo rm -f /etc/resolv.conf
    printf '%s\n' \
        '# managed by fix_dns - xui-multi-tool' \
        'nameserver 1.1.1.1' \
        'nameserver 1.0.0.1' \
        'nameserver 8.8.8.8' \
        'options timeout:2 attempts:3 rotate' | sudo tee /etc/resolv.conf >/dev/null
    if [ "$DO_LOCK" -eq 1 ]; then
        sudo chattr +i /etc/resolv.conf 2>/dev/null && echo "  -> Locked (chattr +i)."
    fi
    # gai.conf IPv4 preference (idempotent)
    grep -v '^#' /etc/gai.conf 2>/dev/null | grep -qF 'precedence ::ffff:0:0/96' || \
        printf '%s\n' '' '# managed by fix_dns - xui-multi-tool' 'precedence ::ffff:0:0/96 100' | sudo tee -a /etc/gai.conf >/dev/null

    local OK=0 h IP
    for h in cloudflare.com google.com archive.ubuntu.com; do
        IP=$(getent ahostsv4 "$h" 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$IP" ]; then OK=$((OK + 1)); echo "  -> $h -> $IP"; else echo "  -> $h FAILED"; fi
    done
    [ "$OK" -eq 3 ] && echo "  -> DNS OK." || echo "  -> DNS PARTIAL ($OK/3 resolved)."
}

# --- FIX: YABS benchmark (network + CPU/disk) ---
fix_yabs() {
    fix_brief "YABS benchmark" \
        "Runs yabs.sh: Geekbench (CPU), fio (disk) and iperf3 network tests against several cities." \
        "A quick, comparable read on a box's CPU/disk/network before trusting it with load." \
        "Low - read-only benchmark, but it uses real uplink bandwidth and takes ~10-25 min." \
        "Nothing to revert - it changes nothing on the server." || { echo "  Cancelled."; return; }

    command -v curl >/dev/null 2>&1 || sudo apt-get install -y curl 2>/dev/null
    echo "  -> Running yabs.sh (this can take 10-25 minutes)..."
    curl -sL yabs.sh | bash
}

# --- FIX: series repair (orphan episode rows) ---
# Ported from xui_monitor/series_repair.py: delete rows in streams_episodes whose
# stream was deleted. Dumps + verifies the table before the DELETE. Series that
# would be emptied entirely are protected (kept) by default.
fix_series_repair() {
    if ! check_xui_installed >/dev/null 2>&1; then check_xui_installed; return; fi

    echo ""
    echo -e "  ${D}Scanning xui.streams_episodes for orphan rows...${N}"
    local scan
    scan=$(sudo mysql -N -e "
        SELECT CONCAT('ORPHANS:', COUNT(*)) FROM xui.streams_episodes e LEFT JOIN xui.streams st ON st.id = e.stream_id WHERE st.id IS NULL;
        SELECT CONCAT('TOTAL:', COUNT(*)) FROM xui.streams_episodes;
        SELECT CONCAT('EMPTIED:', e.series_id, ':', COALESCE(s.title,'?'), ':', COUNT(*))
          FROM xui.streams_episodes e
          LEFT JOIN xui.streams st ON st.id = e.stream_id
          LEFT JOIN xui.streams_series s ON s.id = e.series_id
          GROUP BY e.series_id, s.title
          HAVING SUM(st.id IS NULL) = COUNT(*) AND COUNT(*) > 0;" 2>&1)

    local orphans total
    orphans=$(echo "$scan" | sed -n 's/^ORPHANS://p' | head -1)
    total=$(echo "$scan" | sed -n 's/^TOTAL://p' | head -1)
    if ! [[ "$orphans" =~ ^[0-9]+$ ]]; then
        echo -e "  ${R}Could not read the database (root MySQL access needed). Aborting.${N}"
        return
    fi
    echo "  -> Orphan episode rows: ${orphans} of ${total:-?}"
    [ "$orphans" -eq 0 ] && { echo "  -> Nothing to clean."; return; }

    # Series that would be emptied entirely -> protected (kept) by default.
    local protect_ids="" emptied_lines
    emptied_lines=$(echo "$scan" | sed -n 's/^EMPTIED://p')
    if [ -n "$emptied_lines" ]; then
        echo -e "  ${Y}These series are ONLY dead rows and will be kept (protected):${N}"
        while IFS=':' read -r sid title rows; do
            [ -z "$sid" ] && continue
            [[ "$sid" =~ ^[0-9]+$ ]] || continue
            echo "     - [$sid] ${title} (${rows} rows)"
            protect_ids="${protect_ids:+$protect_ids,}$sid"
        done <<< "$emptied_lines"
    fi

    fix_brief "Series repair (orphan episodes)" \
        "Deletes streams_episodes rows whose stream was deleted. Nothing playable is touched." \
        "Orphan rows are invisible/unplayable and inflate duplicate counts across the panel." \
        "Medium - a DELETE on part of the table; the table is dumped to /home/xui/backups and verified first." \
        "Yes - restore the dumped .sql from /home/xui/backups." || { echo "  Cancelled."; return; }

    sudo mkdir -p /home/xui/backups || { echo "  FAILED: cannot create /home/xui/backups."; return; }
    local F="/home/xui/backups/streams_episodes_$(date +%Y%m%d_%H%M%S).sql"
    if ! sudo mysqldump --single-transaction xui streams_episodes | sudo tee "$F" >/dev/null; then
        echo "  FAILED: dump could not be written. Aborting (no delete)."
        return
    fi
    if ! sudo grep -q 'INSERT INTO' "$F"; then
        echo "  FAILED: dump has no data (empty safety net). Aborting (no delete)."
        return
    fi
    echo "  -> Backup: $F"

    local where_extra=""
    [ -n "$protect_ids" ] && where_extra=" AND e.series_id NOT IN ($protect_ids)"
    local out
    out=$(sudo mysql -N xui -e "DELETE e FROM streams_episodes e LEFT JOIN streams st ON st.id = e.stream_id WHERE st.id IS NULL${where_extra}; SELECT CONCAT('DELETED:', ROW_COUNT());" 2>&1)
    local deleted
    deleted=$(echo "$out" | sed -n 's/^DELETED://p' | head -1)
    if [[ "$deleted" =~ ^[0-9]+$ ]]; then
        echo -e "  ${G}Done. Deleted ${deleted} orphan rows.${N} Backup kept at $F"
    else
        echo -e "  ${R}DELETE failed:${N}"; echo "$out" | tail -3
        echo "  Table is unchanged / restore from $F if needed."
    fi
}

# --- FIX: archive / timeshift cleanup ---
# Ported from xui_monitor: disable XUI's own archive cleanup and delete the
# .ts.offset markers (XUI counts each as a file against days*1440, so recorders
# discard half the days they were told to keep). Recordings are NOT touched.
fix_archive_cleanup() {
    if ! check_xui_installed >/dev/null 2>&1; then check_xui_installed; return; fi

    local APATH="/home/xui/content/archive"
    [ -d "$APATH" ] || APATH="/home/xui/tv_archive"
    if [ ! -d "$APATH" ]; then
        echo "  -> No archive directory found (/home/xui/content/archive or /home/xui/tv_archive)."
        return
    fi
    local offn
    offn=$(sudo find "$APATH" -name '*.ts.offset' 2>/dev/null | wc -l)
    echo "  -> Archive path: $APATH"
    echo "  -> .ts.offset markers found: $offn"

    fix_brief "Archive / timeshift cleanup" \
        "Turns off XUI's own archive cleanup (settings.cleanup=0) and deletes the .ts.offset markers." \
        "XUI counts each .ts.offset as a file against days*1440, so recorders discard half the days they should keep." \
        "Medium - deletes .ts.offset MARKER files (not the recordings) and changes one panel setting." \
        "settings.cleanup can be set back to 1; markers regenerate as new segments record." || { echo "  Cancelled."; return; }

    sudo mysql -N -e "UPDATE xui.settings SET cleanup=0;" 2>&1
    local cl
    cl=$(sudo mysql -N -e "SELECT cleanup FROM xui.settings LIMIT 1;" 2>/dev/null)
    if [ "$cl" = "0" ]; then
        echo "  -> XUI archive cleanup disabled (settings.cleanup=0)."
    else
        echo "  -> WARNING: could not confirm settings.cleanup=0 (root MySQL needed)."
    fi

    if [ "$offn" -gt 0 ]; then
        sudo find "$APATH" -name '*.ts.offset' -delete 2>/dev/null
        local left
        left=$(sudo find "$APATH" -name '*.ts.offset' 2>/dev/null | wc -l)
        echo "  -> Removed $((offn - left)) .ts.offset markers ($left remaining)."
    else
        echo "  -> No .ts.offset markers to delete."
    fi
}

# --- FIX: SSL / certbot (core subset ported from xui_monitor) ---
# Finds certbot across XUI layouts, shows the certificate nginx actually serves
# (read from ssl.conf), and offers a dry-run or a real renew + nginx reload.
# The bot's full lineage management (issue/delete/sync across servers) is not
# ported - this is the day-to-day renewal path.
fix_ssl() {
    if ! check_xui_installed >/dev/null 2>&1; then check_xui_installed; return; fi
    local SSLCONF="/home/xui/bin/nginx/conf/ssl.conf"

    local CB="" CFG="" p d
    for p in /home/xui/bin/certbot-auto /home/xui/bin/certbot/certbot-auto \
             /home/xui/bin/certbot/bin/certbot /home/xui/bin/certbot/certbot \
             "$(command -v certbot 2>/dev/null)"; do
        [ -n "$p" ] && [ -x "$p" ] && CB="$p" && break
    done
    for d in /home/xui/bin/certbot/config /home/xui/certbot/config /etc/letsencrypt; do
        [ -d "$d/live" ] && CFG="$d" && break
    done
    [ -z "$CFG" ] && for d in /home/xui/bin/certbot/config /etc/letsencrypt; do
        [ -d "$d" ] && CFG="$d" && break
    done
    if [ -z "$CB" ]; then
        echo "  -> certbot not found under /home/xui/bin or PATH."
        echo "     Run 'Fix Compatibility' (installs a certbot wrapper) or 'apt install certbot' first."
        return
    fi
    local CF=""
    [ -n "$CFG" ] && CF="--config-dir $CFG"
    echo "  -> certbot:    $CB"
    echo "  -> config dir: ${CFG:-<none>}"

    local served="" certfile=""
    if sudo test -f "$SSLCONF"; then
        certfile=$(sudo grep -oP 'ssl_certificate\s+\K[^;]+' "$SSLCONF" 2>/dev/null | head -1 | tr -d ' ')
        served=$(echo "$certfile" | grep -oP '/live/\K[^/]+' | head -1)
    fi
    echo "  -> nginx serves: ${served:-<unknown>}"
    if [ -n "$certfile" ] && sudo test -f "$certfile"; then
        echo "  -> expires:      $(sudo openssl x509 -enddate -noout -in "$certfile" 2>/dev/null | cut -d= -f2)"
    fi

    echo ""
    echo "  1) Dry-run renew (test, no changes)"
    echo "  2) Renew now + reload nginx"
    echo "  3) Cancel"
    read -p "  $(echo -e "${C}Select: ${N}")" s
    case "$s" in
        1) sudo "$CB" renew $CF --dry-run ;;
        2)
            fix_brief "Renew SSL certificate(s)" \
                "Runs 'certbot renew' for the panel's certificates and reloads nginx." \
                "Expired certificates break the panel and player TLS; renewal keeps them valid." \
                "Low - certbot only replaces certs that are due; nginx is reloaded, not restarted." \
                "certbot versions each lineage; the previous one stays in ${CFG:-the config dir}." || { echo "  Cancelled."; return; }
            sudo "$CB" renew $CF
            if sudo /home/xui/bin/nginx/sbin/nginx -s reload 2>/dev/null; then
                echo "  -> nginx reloaded."
            else
                echo "  -> NOTE: reload nginx manually (sudo /home/xui/bin/nginx/sbin/nginx -s reload)."
            fi
            ;;
        *) echo "  Cancelled." ;;
    esac
}

# --- FIX: MaxMind GeoIP databases (runs the Python updater) ---
# The DB refresh needs an mmdb schema conversion (GeoLite2-ASN -> GeoIP2-ISP)
# that only the Python updater does, so this downloads and runs the same
# maxmind_updater.dat the bot uses rather than reimplementing it in bash.
# Deploy: upload server/maxmind_updater.dat to https://<BASE_URL>/maxmind_updater.dat.
fix_maxmind() {
    if ! check_xui_installed >/dev/null 2>&1; then check_xui_installed; return; fi

    fix_brief "MaxMind GeoIP update" \
        "Downloads current GeoLite2 databases (Country/City/ASN->ISP) and installs them into the panel's GeoIP paths." \
        "XUI's geo features (per-country rules, ISP labels) go stale without periodic MaxMind refreshes." \
        "Low - the updater verifies each database before replacing the live one and keeps the previous set." \
        "Yes - the previous databases are kept by the updater." || { echo "  Cancelled."; return; }

    command -v python3 >/dev/null 2>&1 || sudo apt-get install -y python3 2>/dev/null
    if ! command -v python3 >/dev/null 2>&1; then
        echo "  -> python3 is required and could not be installed. Aborting."
        return
    fi

    local KEY ACCT
    read -rs -p "  $(echo -e "${C}MaxMind license key: ${N}")" KEY; echo ""
    [ -z "$KEY" ] && { echo "  -> No license key given. Aborting."; return; }
    read -p "  $(echo -e "${C}MaxMind account id (optional, Enter to skip): ${N}")" ACCT

    local UPD="/tmp/maxmind_updater_$$.dat"
    echo "  -> Downloading the updater..."
    if ! wget -qO "$UPD" --user="$XUI_AUTH_USER" --password="$XUI_AUTH_PASS" \
            --user-agent="Mozilla/5.0" "https://$BASE_URL/maxmind_updater.dat" || [ ! -s "$UPD" ]; then
        echo "  -> Could not download maxmind_updater.dat."
        echo "     Upload it to https://$BASE_URL/maxmind_updater.dat (see server/ in the repo)."
        rm -f "$UPD"
        return
    fi

    # Safety: refuse the legacy / DB-IP updater generations (mirrors the bot).
    if ! grep -q -- '--check' "$UPD"; then
        echo "  -> Refusing: legacy updater (no --check; would run destructively)."; rm -f "$UPD"; return
    fi
    if grep -q 'download.db-ip.com' "$UPD"; then
        echo "  -> Refusing: DB-IP updater build (oversized databases)."; rm -f "$UPD"; return
    fi

    echo "  -> Running the updater (up to ~15 min)..."
    sudo env MM_LICENSE_KEY="$KEY" MM_ACCOUNT_ID="$ACCT" python3 "$UPD"
    local rc=$?
    rm -f "$UPD"
    [ "$rc" -eq 0 ] && echo "  -> MaxMind databases updated." || echo "  -> Updater exited with code $rc (see output above)."
}

# --- FIX: compile ffmpeg into the panel's 4.4 slot ---
# Runs the exact build recipe from xui_monitor (ffbuild_seg0/1.sh), which
# compiles ffmpeg 4.4.5 with XUI's feature set, verifies it runs, checks it
# against the panel's own live command, and only then installs it - keeping the
# old binary as .orig (and a non-running one as .broken). The build script is
# chosen by the panel's segment_type (0=hls, 1=segment, which needs the
# +live+delete patch). Deploy: upload server/ffbuild_seg0.sh and
# server/ffbuild_seg1.sh next to core_menu.sh.
fix_ffmpeg_build() {
    if ! check_xui_installed >/dev/null 2>&1; then check_xui_installed; return; fi

    local SEG
    SEG=$(sudo mysql -N -e "SELECT segment_type FROM xui.settings LIMIT 1;" 2>/dev/null | tr -cd '01' | head -c1)
    if [ "$SEG" != "0" ] && [ "$SEG" != "1" ]; then
        echo "  -> Could not read xui.settings.segment_type (need root MySQL). Aborting."
        return
    fi
    if [ "$SEG" = "1" ]; then
        echo "  -> Panel segment_type: 1 (-f segment; the build gets XUI's +live+delete patch)"
    else
        echo "  -> Panel segment_type: 0 (-f hls; stock flags)"
    fi

    fix_brief "Compile ffmpeg 4.4.5 -> 4.4 slot" \
        "Compiles ffmpeg 4.4.5 from source with XUI's feature set and installs it into the panel's 4.4 slot." \
        "XUI's shipped static ffmpeg dies on glibc 2.34+ (Ubuntu 22.04+); a from-source build restores streaming." \
        "HIGH - replaces the panel's ffmpeg binary and takes ~30 min. The old binary is kept as .orig; a build that will not run is kept as .broken and NOT installed." \
        "Yes - copy /home/xui/bin/ffmpeg_bin/4.4/<bin>.orig back over <bin>." || { echo "  Cancelled."; return; }

    local D="/root/xui_ffbuild"
    sudo mkdir -p "$D"
    printf '%s' "$SEG" | sudo tee "$D/segtype" >/dev/null

    # Codecs the panel's own profiles require -> the build refuses to install if
    # any is missing (faithful to the bot's "wanted" check). Same parser as the
    # bot, over profiles.profile_options + streams.custom_ffmpeg.
    local RAW
    RAW=$( { sudo mysql -N -B -e "SELECT profile_options FROM xui.profiles;" 2>/dev/null; \
             sudo mysql -N -B -e "SELECT DISTINCT custom_ffmpeg FROM xui.streams WHERE custom_ffmpeg IS NOT NULL AND custom_ffmpeg <> '';" 2>/dev/null; } )
    if command -v python3 >/dev/null 2>&1; then
        printf '%s\n' "$RAW" | python3 -c '
import re,sys
keys=("-vcodec","-acodec","-scodec","-c:v","-c:a","-c:s","-codec:v","-codec:a","-codec")
NOT={"copy","none","auto","default","","0","1"}
pat=re.compile(r"(?:%s)[\"\x27]?\s*[:=]?\s*[\"\x27]?\s*([A-Za-z0-9_.+-]+)"%"|".join(re.escape(k) for k in keys))
w=set()
for line in sys.stdin:
    for m in pat.finditer(line):
        n=m.group(1).strip().strip("\"\x27")
        if n.lower() not in NOT and not n.startswith("-"): w.add(n)
print("\n".join(sorted(w)))
' | sudo tee "$D/wanted_req" >/dev/null
        local WN
        WN=$(sudo grep -c . "$D/wanted_req" 2>/dev/null || echo 0)
        echo "  -> Panel profiles require ${WN} codec(s); the build will refuse to install if any is missing."
    else
        printf '' | sudo tee "$D/wanted_req" >/dev/null
        echo "  -> python3 not present: profile-codec enforcement skipped (build still verifies it runs)."
    fi

    echo "  -> Downloading the build recipe (ffbuild_seg${SEG}.sh)..."
    if ! sudo wget -qO "$D/build.sh" --user="$XUI_AUTH_USER" --password="$XUI_AUTH_PASS" \
            --user-agent="Mozilla/5.0" "https://$BASE_URL/ffbuild_seg${SEG}.sh" || ! sudo test -s "$D/build.sh"; then
        echo "  -> Could not download ffbuild_seg${SEG}.sh."
        echo "     Upload server/ffbuild_seg0.sh and ffbuild_seg1.sh to https://$BASE_URL/ ."
        return
    fi
    sudo chmod 0755 "$D/build.sh"

    echo "  -> Building (this takes ~30 minutes). Live log below (Ctrl-C stops watching, not the build):"
    printf '' | sudo tee "$D/build.log" >/dev/null
    sudo bash "$D/build.sh" &
    local BPID=$!
    sudo tail -f "$D/build.log" &
    local TPID=$!
    wait "$BPID"; local rc=$?
    sleep 1; sudo kill "$TPID" 2>/dev/null

    echo ""
    echo "  -> Final state: $(sudo tail -1 "$D/state" 2>/dev/null)"
    if [ "$rc" -eq 0 ]; then
        echo "  -> Slot 4.4 now: $(/home/xui/bin/ffmpeg_bin/4.4/ffmpeg -version 2>/dev/null | head -1)"
    else
        echo "  -> Build did not complete (exit $rc). See $D/build.log; reasons:"
        sudo tail -5 "$D/why" 2>/dev/null
    fi
}

# --- FIX: repair the XUI system user / ownership ---
# On some servers the 'xui' user/group entry is lost (a failed uninstall, a
# migration, a manual cleanup). The files keep their numeric uid/gid, which then
# resolve to whatever names now hold those ids (e.g. fwupd-refresh:_ssh), and the
# panel - which runs AS 'xui' - breaks. This recreates the user/group if missing
# and restores ownership of /home/xui to xui:xui.
fix_xui_user() {
    if [ ! -d /home/xui ]; then
        echo "  -> /home/xui not found. Nothing to repair."
        return
    fi
    echo "  -> /home/xui is currently owned by: $(stat -c '%U:%G (uid %u, gid %g)' /home/xui 2>/dev/null)"
    if id xui >/dev/null 2>&1; then
        echo "  -> The 'xui' user EXISTS (uid $(id -u xui), gid $(id -g xui))."
    else
        echo "  -> The 'xui' user is MISSING - the panel's account was lost."
    fi

    fix_brief "Repair XUI user & ownership" \
        "Recreates the 'xui' user/group if missing and chowns /home/xui back to xui:xui." \
        "XUI.ONE runs as the 'xui' user; if that account is gone the panel, crons and ffmpeg fail." \
        "Medium - runs chown -R over /home/xui (slow on large content); no data is deleted." \
        "Ownership can be pointed back at the current owner later if ever needed." || { echo "  Cancelled."; return; }

    getent group xui >/dev/null 2>&1 || { sudo groupadd --system xui && echo "  -> Created group 'xui'."; }
    if ! id xui >/dev/null 2>&1; then
        sudo useradd --system --no-create-home --home-dir /home/xui --shell /bin/bash --gid xui xui \
            && echo "  -> Created user 'xui'."
    fi

    echo "  -> Restoring ownership (chown -R xui:xui /home/xui) - this may take a while..."
    sudo chown -R xui:xui /home/xui
    echo "  -> Done. /home/xui now owned by: $(stat -c '%U:%G' /home/xui 2>/dev/null)"

    if systemctl list-unit-files 2>/dev/null | grep -q '^xuione'; then
        read -p "  $(echo -e "${C}Restart the xuione service now? (y/N): ${N}")" rs
        [[ "$rs" =~ ^[Yy]$ ]] && { sudo systemctl restart xuione && echo "  -> xuione restarted."; }
    fi
}

# ============================================================
# STATUS / DIAGNOSTICS
# ============================================================

show_status() {
    echo "=========================================="
    echo " SYSTEM DIAGNOSTICS"
    echo "=========================================="
    detect_os
    echo ""

    # MariaDB version
    if command -v mysql &>/dev/null; then
        MARIA_VER=$(mysql -V 2>/dev/null)
        echo "MariaDB: $MARIA_VER"
    else
        echo "MariaDB: NOT INSTALLED"
    fi

    # XUI status
    if [ -d "/home/xui" ]; then
        echo "XUI Directory: EXISTS"
        if [ -f "/home/xui/config/config.ini" ]; then
            LIC=$(grep -oP 'license\s*=\s*"\K[^"]+' /home/xui/config/config.ini 2>/dev/null)
            echo "License: $LIC"
        fi
    else
        echo "XUI Directory: NOT FOUND"
    fi

    # Service status
    if systemctl is-active xuione &>/dev/null; then
        echo "XUI Service: RUNNING"
    else
        echo "XUI Service: STOPPED"
    fi

    # nginx version
    if [ -f /home/xui/bin/nginx/sbin/nginx ]; then
        NGX=$(/home/xui/bin/nginx/sbin/nginx -v 2>&1)
        echo "Nginx: $NGX"
    fi

    # PHP version
    if [ -f /home/xui/bin/php/bin/php ]; then
        PHP=$(/home/xui/bin/php/bin/php -v 2>/dev/null | head -1)
        echo "PHP: $PHP"
    fi

    # libssl1.1
    if ldconfig -p | grep -q "libssl.so.1.1"; then
        echo "libssl1.1: INSTALLED"
    else
        echo "libssl1.1: MISSING (CRITICAL)"
    fi

    # Disk space
    echo ""
    echo "Disk Usage:"
    df -h / | tail -1 | awk '{print "  Root: " $3 " used / " $2 " total (" $5 " used)"}'
    if mount | grep -q "/home/xui/content/streams"; then
        df -h /home/xui/content/streams | tail -1 | awk '{print "  Streams tmpfs: " $3 " used / " $2 " total"}'
    fi

    echo "=========================================="
}

# ============================================================
# COLORS & UI
# ============================================================

# Colors
R='\033[0;31m'      # Red
G='\033[0;32m'      # Green
Y='\033[1;33m'      # Yellow
C='\033[0;36m'      # Cyan
M='\033[0;35m'      # Magenta
W='\033[1;37m'      # White Bold
D='\033[0;90m'      # Dark Gray
N='\033[0m'         # Reset

# UI drawing functions
draw_line() {
    echo -e "${D}  +-------------------------------------------------+${N}"
}

draw_line_double() {
    echo -e "${C}  +${D}==================================================${C}+${N}"
}

draw_empty() {
    echo -e "${D}  |                                                  |${N}"
}

draw_text() {
    local text="$1"
    local color="${2:-$W}"
    # Strip ANSI codes for length calculation
    local clean_text=$(echo -e "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local len=${#clean_text}
    local pad=$(( (48 - len) / 2 ))
    local pad_r=$(( 48 - len - pad ))
    printf "${D}  |${N}%${pad}s${color}%s${N}%${pad_r}s${D}|${N}\n" "" "$text" ""
}

draw_option() {
    local key="$1"
    local text="$2"
    local desc="${3:-}"
    if [ -n "$desc" ]; then
        printf "${D}  |  ${C}[${W}%s${C}]${N} %-20s ${D}%s${N}%*s${D}|${N}\n" "$key" "$text" "$desc" $(( 22 - ${#desc} )) ""
    else
        printf "${D}  |  ${C}[${W}%s${C}]${N} %-43s${D}|${N}\n" "$key" "$text"
    fi
}

pause_return() {
    echo ""
    echo -e "  ${D}Press [Enter] to return...${N}"
    read
}

# ============================================================
# BANNER
# ============================================================

show_banner() {
    echo ""
    echo -e "${C}  __  ___   _ ___   ___  _  _ ___${N}"
    echo -e "${C}  \\ \\/ / | | |_ _| / _ \\| \\| | __|${N}"
    echo -e "${C}   >  <| |_| || | | (_) | .\` | _|${N}"
    echo -e "${C}  /_/\\_\\\\___/|___| \\___/|_|\\_|___|${N}"
    echo -e "${D}  ----------------------------------------${N}"
    echo -e "${W}  M U L T I - T O O L${N}  ${G}v${MULTITOOL_VERSION}${N} ${D}(for XUI.ONE 1.5.13)${N}"
    echo -e "${D}  by ${M}@tealcavalon${D} | Improved Edition${N}"
    echo -e "${D}  ----------------------------------------${N}"
    echo ""
    echo -e "  ${D}User:${N} ${G}$XUI_AUTH_USER${N}  ${D}|${N}  ${D}OS:${N} ${G}Ubuntu $OS_VERSION${N} ${D}($OS_CODENAME)${N}"
    echo ""
}

# ============================================================
# MAIN MENU
# ============================================================

show_main_menu() {
    clear
    show_banner
    draw_line_double
    draw_empty
    draw_text "MAIN MENU" "$Y"
    draw_empty
    draw_line
    draw_empty
    draw_option "1" "Installation" "Install & Setup"
    draw_empty
    draw_option "2" "Tools" "Server Management"
    draw_empty
    draw_option "3" "Information" "Diagnostics & Status"
    draw_empty
    draw_line
    draw_empty
    draw_option "F" "FULL SETUP" "Complete install"
    draw_empty
    draw_line
    draw_empty
    draw_option "Q" "Exit"
    draw_empty
    draw_line_double
    echo ""
}

# ============================================================
# INSTALL SUBMENU
# ============================================================

show_install_menu() {
    while true; do
        clear
        show_banner
        draw_line_double
        draw_empty
        draw_text "INSTALLATION" "$R"
        draw_empty
        draw_line
        draw_empty
        draw_option "1" "Install XUI.ONE 1.5.13" "no patch needed"
        draw_empty
        draw_option "2" "Install MariaDB $MARIADB_SERIES" "force + hold"
        draw_empty
        draw_option "3" "Install Telegram BOT" "XUI Monitor"
        draw_empty
        draw_line
        draw_empty
        draw_option "B" "Back to Main Menu"
        draw_empty
        draw_line_double
        echo ""
        read -p "  $(echo -e "${C}>${N}") " opt

        case $opt in
            1) install_xui ; pause_return ;;
            2) install_mariadb ; pause_return ;;
            3)
                echo ""
                echo -e "  ${C}XUI Monitor - Telegram BOT${N}"
                echo -e "  ${D}Guide: ${W}https://tealc.pw/@tealcavalon/xui-monitor/BOT_GUIDE.html${N}"
                echo ""
                echo -e "  ${Y}This option will install the Telegram BOT.${N}"
                echo -e "  ${Y}Please check the guide above for more information.${N}"
                echo ""
                echo -e "  ${R}NOTE:${N} ${W}This BOT requires separate credentials.${N}"
                echo -e "  ${W}They are NOT the same as the ones used in this script.${N}"
                echo -e "  ${W}This is a ${R}restricted and paid${W} access service.${N}"
                echo -e "  ${W}Contact ${M}@tealcavalon${W} to request access.${N}"
                echo ""
                read -p "  $(echo -e "${C}Do you want to continue? (Y/N): ${N}")" confirm
                if [[ "$confirm" =~ ^[SsYy]$ ]]; then
                    echo ""
                    echo -e "  ${G}Starting installation...${N}"
                    echo ""
                    curl -sL https://tealc.pw/@tealcavalon/xui-monitor/install.sh | bash
                    exit 0
                else
                    echo -e "  ${D}Installation cancelled.${N}"
                    sleep 1
                fi
                ;;
            b|B) return ;;
            *) ;;
        esac
    done
}

# ============================================================
# TOOLS SUBMENU
# ============================================================

show_tools_menu() {
    while true; do
        clear
        show_banner
        draw_line_double
        draw_empty
        draw_text "SERVER TOOLS" "$G"
        draw_empty
        draw_line
        draw_empty
        draw_option "1" "Apply License Patch" "standalone"
        draw_empty
        draw_option "2" "Fix Compatibility" "Ubuntu 22/24+"
        draw_empty
        draw_option "3" "Hardware Optimizer" "MySQL + Kernel"
        draw_empty
        draw_option "4" "Secure MySQL" "Firewall + Brute"
        draw_empty
        draw_option "5" "Recompile Nginx" "latest version"
        draw_empty
        draw_option "6" "Import Database" ".sql / .sql.gz / MEGA"
        draw_empty
        draw_option "7" "Secure SSH" "Hardening + Keys"
        draw_empty
        draw_line
        draw_empty
        draw_text "FIXES (ported from bot)" "$Y"
        draw_empty
        draw_option "8"  "Prefer IPv4" "gai.conf"
        draw_empty
        draw_option "9"  "DNS resolvers" "static resolv.conf"
        draw_empty
        draw_option "10" "Time sync" "timezone + NTP"
        draw_empty
        draw_option "11" "Disable apport" "crash reporter"
        draw_empty
        draw_option "12" "YABS benchmark" "CPU/disk/net"
        draw_empty
        draw_option "13" "Series repair" "orphan episodes"
        draw_empty
        draw_option "14" "Archive cleanup" "timeshift .offset"
        draw_empty
        draw_option "15" "SSL / certbot" "renew + reload"
        draw_empty
        draw_option "16" "MaxMind GeoIP" "update databases"
        draw_empty
        draw_option "17" "Build ffmpeg 4.4" "compile -> slot"
        draw_empty
        draw_option "18" "Repair XUI user" "owner -> xui:xui"
        draw_empty
        draw_line
        draw_empty
        draw_option "B" "Back to Main Menu"
        draw_empty
        draw_line_double
        echo ""
        read -p "  $(echo -e "${C}>${N}") " opt

        case $opt in
            1) apply_patch ; pause_return ;;
            2) fix_ubuntu_24 ; pause_return ;;
            3) optimize_server ; pause_return ;;
            4) secure_mysql ; pause_return ;;
            5) recompile_nginx ; pause_return ;;
            6) import_database ; pause_return ;;
            7) secure_ssh ; pause_return ;;
            8) fix_ipv6_pref ; pause_return ;;
            9) fix_dns ; pause_return ;;
            10) fix_timesync ; pause_return ;;
            11) fix_apport ; pause_return ;;
            12) fix_yabs ; pause_return ;;
            13) fix_series_repair ; pause_return ;;
            14) fix_archive_cleanup ; pause_return ;;
            15) fix_ssl ; pause_return ;;
            16) fix_maxmind ; pause_return ;;
            17) fix_ffmpeg_build ; pause_return ;;
            18) fix_xui_user ; pause_return ;;
            b|B) return ;;
            *) ;;
        esac
    done
}

# ============================================================
# INFO SUBMENU
# ============================================================

show_info_menu() {
    while true; do
        clear
        show_banner
        draw_line_double
        draw_empty
        draw_text "INFORMATION" "$M"
        draw_empty
        draw_line
        draw_empty
        draw_option "1" "System Diagnostics" "full check"
        draw_empty
        draw_option "2" "Quick Status" "service check"
        draw_empty
        draw_option "3" "MariaDB Status" "version + hold"
        draw_empty
        draw_line
        draw_empty
        draw_option "B" "Back to Main Menu"
        draw_empty
        draw_line_double
        echo ""
        read -p "  $(echo -e "${C}>${N}") " opt

        case $opt in
            1) show_status ; pause_return ;;
            2)
                echo ""
                if systemctl is-active xuione &>/dev/null; then
                    echo -e "  ${G}XUI.ONE service: RUNNING${N}"
                else
                    echo -e "  ${R}XUI.ONE service: STOPPED${N}"
                fi
                if systemctl is-active mariadb &>/dev/null; then
                    echo -e "  ${G}MariaDB service: RUNNING${N}"
                else
                    echo -e "  ${R}MariaDB service: STOPPED${N}"
                fi
                if [ -f /home/xui/bin/nginx/sbin/nginx ]; then
                    NGX=$(/home/xui/bin/nginx/sbin/nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+')
                    echo -e "  ${G}Nginx version:   $NGX${N}"
                fi
                pause_return
                ;;
            3)
                echo ""
                if command -v mysql &>/dev/null; then
                    VER=$(mysql -V 2>/dev/null | grep -oP 'Distrib \K[0-9.]+')
                    echo -e "  ${G}MariaDB version: $VER${N}"
                else
                    echo -e "  ${R}MariaDB: NOT INSTALLED${N}"
                fi
                echo ""
                HELD=$(apt-mark showhold 2>/dev/null | grep -iE "mariadb|galera|mysql")
                if [ -n "$HELD" ]; then
                    echo -e "  ${Y}Packages on HOLD (upgrade blocked):${N}"
                    echo "$HELD" | while read p; do echo -e "    ${D}-${N} $p"; done
                else
                    echo -e "  ${R}WARNING: No MariaDB packages on hold!${N}"
                    echo -e "  ${D}Run Install > MariaDB $MARIADB_SERIES to fix this.${N}"
                fi
                pause_return
                ;;
            b|B) return ;;
            *) ;;
        esac
    done
}

# ============================================================
# FULL SETUP
# ============================================================

run_full_setup() {
    clear
    echo ""
    echo -e "${R}"
    echo '    _____ _   _ _    _       ____ _____ _____ _   _ ____  '
    echo '   |  ___| | | | |  | |     / ___|_   _|_   _| | | |  _ \ '
    echo '   | |_  | | | | |  | |     \___ \ | |   | | | | | | |_) |'
    echo '   |  _| | |_| | |__| |___   ___) || |   | | | |_| |  __/ '
    echo '   |_|    \___/|_____|_____| |____/ |_|   |_|  \___/|_|    '
    echo -e "${N}"
    echo -e "  ${D}This will run the complete installation sequence:${N}"
    echo ""
    echo -e "  ${C}1.${N} Fix compatibility (if needed)"
    echo -e "  ${C}2.${N} Install & lock MariaDB $MARIADB_SERIES"
    echo -e "  ${C}3.${N} Install XUI.ONE 1.5.13"
    echo -e "  ${C}4.${N} Import database (optional)"
    echo -e "  ${C}5.${N} Optimize server hardware"
    echo -e "  ${C}6.${N} Secure MySQL firewall"
    echo ""
    draw_line
    echo ""
    read -p "  $(echo -e "${Y}Start full setup? (y/n):${N}") " START_FULL
    if [[ "$START_FULL" != "y" && "$START_FULL" != "Y" ]]; then
        echo -e "  ${D}Cancelled.${N}"
        return
    fi

    echo ""
    echo -e "  ${C}[1/6]${N} ${W}Compatibility fixes...${N}"
    echo -e "  ${D}----------------------------------------------${N}"
    detect_os
    fix_compatibility

    echo ""
    echo -e "  ${C}[2/6]${N} ${W}MariaDB $MARIADB_SERIES...${N}"
    echo -e "  ${D}----------------------------------------------${N}"
    force_mariadb

    echo ""
    echo -e "  ${C}[3/6]${N} ${W}XUI.ONE 1.5.13...${N}"
    echo -e "  ${D}----------------------------------------------${N}"
    install_xui skip-fixes

    echo ""
    echo -e "  ${C}[4/6]${N} ${W}Database import...${N}"
    echo -e "  ${D}----------------------------------------------${N}"
    read -p "  $(echo -e "${Y}Import an existing database? (y/n):${N}") " IMPORT_DB
    if [[ "$IMPORT_DB" == "y" || "$IMPORT_DB" == "Y" ]]; then
        import_database
    else
        echo -e "  ${D}Skipped.${N}"
    fi

    echo ""
    echo -e "  ${C}[5/6]${N} ${W}Hardware optimization...${N}"
    echo -e "  ${D}----------------------------------------------${N}"
    optimize_server

    echo ""
    echo -e "  ${C}[6/6]${N} ${W}MySQL security...${N}"
    echo -e "  ${D}----------------------------------------------${N}"
    secure_mysql

    echo ""
    echo -e "${G}"
    echo '   ____   ___  _   _ _____ _ '
    echo '  |  _ \ / _ \| \ | | ____| |'
    echo '  | | | | | | |  \| |  _| | |'
    echo '  | |_| | |_| | |\  | |___|_|'
    echo '  |____/ \___/|_| \_|_____(_)'
    echo -e "${N}"
    echo -e "  ${W}Full setup completed successfully!${N}"
    echo ""
}

# ============================================================
# MAIN LOOP
# ============================================================

# Detect OS once at startup
detect_os

while true; do
    show_main_menu
    read -p "  $(echo -e "${C}>${N}") " opt

    case $opt in
        1) show_install_menu ;;
        2) show_tools_menu ;;
        3) show_info_menu ;;
        f|F) run_full_setup ; pause_return ;;
        q|Q)
            clear
            echo ""
            echo -e "${C}  __  ___   _ ___   ___  _  _ ___${N}"
            echo -e "${C}  \\ \\/ / | | |_ _| / _ \\| \\| | __|${N}"
            echo -e "${C}   >  <| |_| || | | (_) | .\` | _|${N}"
            echo -e "${C}  /_/\\_\\\\___/|___| \\___/|_|\\_|___|${N}"
            echo ""
            echo -e "  ${D}Session terminated. Stay safe.${N}"
            echo ""
            exit 0
            ;;
        *) ;;
    esac
done
