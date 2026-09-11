#!/bin/bash

# --- Configuration ---
BASE_URL="tealc.pw/stuff/xuione/new"

# Colors
R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
M='\033[0;35m'
W='\033[1;37m'
D='\033[0;90m'
N='\033[0m'

# ============================================================
# HELPERS
# ============================================================

# URL-encode a string for an application/x-www-form-urlencoded POST body.
urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# Report this access to the server-side logging / rate-limit endpoint.
# The endpoint sits behind the same HTTP Basic auth as the rest of the tool, so
# it identifies the user from the authenticated session (not spoofable) and
# enforces the per-account server/IP limit itself - the loader no longer holds
# any logging credentials. Prints the server's plain-text response.
log_access() {
    local status="$1"
    local host_name os_name
    host_name=$(hostname 2>/dev/null || echo "unknown")
    os_name=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown")
    wget -qO- --user="$AUTH_USER" --password="$AUTH_PASS" --user-agent="Mozilla/5.0" \
        --post-data="status=${status}&hostname=$(urlencode "$host_name")&os=$(urlencode "$os_name")" \
        "https://$BASE_URL/log_access.php" 2>/dev/null
}

# ============================================================
# MAIN LOGIN FLOW
# ============================================================

clear
echo ""
echo -e "${C}  __  ___   _ ___   ___  _  _ ___${N}"
echo -e "${C}  \\ \\/ / | | |_ _| / _ \\| \\| | __|${N}"
echo -e "${C}   >  <| |_| || | | (_) | .\` | _|${N}"
echo -e "${C}  /_/\\_\\\\___/|___| \\___/|_|\\_|___|${N}"
echo ""
echo -e "  ${D}+-------------------------------------------------+${N}"
echo -e "  ${D}|${N}  ${W}M U L T I - T O O L${N}  ${D}v1.5.13${N}                  ${D}|${N}"
echo -e "  ${D}|${N}  ${D}by${N} ${M}@tealcavalon${N}  ${D}|${N}  ${D}t.me/tealcavalon${N}        ${D}|${N}"
echo -e "  ${D}+-------------------------------------------------+${N}"
echo ""
echo -e "  ${D}Login to continue${N}"
echo ""
read -r -p "  $(echo -e "${C}  Username: ${N}")" AUTH_USER
read -rs -p "  $(echo -e "${C}  Password: ${N}")" AUTH_PASS
echo ""
echo ""
echo -e "  ${D}Validating credentials...${N}"

# Check if credentials are valid
TEST_RESULT=$(wget -qO- --user="$AUTH_USER" --password="$AUTH_PASS" --user-agent="Mozilla/5.0" "https://$BASE_URL/test_user_pass" 2>/dev/null)

if [[ "$TEST_RESULT" == *"ok"* ]]; then

    echo -e "  ${D}Checking access...${N}"

    # Log the access + check the per-account server/IP limit (server-side).
    ACCESS_RESULT=$(log_access "GRANTED")

    if [[ "$ACCESS_RESULT" == BLOCKED* ]]; then
        MAXN=$(echo "$ACCESS_RESULT" | sed -n 's/^max=//p')
        YOURIP=$(echo "$ACCESS_RESULT" | sed -n 's/^your_ip=//p')
        echo ""
        echo -e "  ${R}+-------------------------------------------------+${N}"
        echo -e "  ${R}|           IP LIMIT EXCEEDED                      |${N}"
        echo -e "  ${R}+-------------------------------------------------+${N}"
        echo ""
        echo -e "  ${Y}This account has reached the maximum of ${W}${MAXN:-?}${Y} different${N}"
        echo -e "  ${Y}servers/IPs in the last 24 hours.${N}"
        echo ""
        echo -e "  ${W}Currently registered sources:${N}"
        echo "$ACCESS_RESULT" | sed -n 's/^source=/    - /p' | while read -r line; do
            echo -e "  ${C}${line}${N}"
        done
        [ -n "$YOURIP" ] && echo -e "  ${D}Your IP: ${YOURIP}${N}"
        echo ""
        echo -e "  ${D}Please wait 24h or use one of the registered servers.${N}"
        echo ""
        exit 1
    fi

    if [[ "$ACCESS_RESULT" != GRANTED* ]]; then
        # Endpoint unreachable or unexpected reply. Fail open (credentials were
        # already validated above) but let the user know logging may have failed.
        echo -e "  ${Y}Note: logging endpoint did not respond as expected; continuing.${N}"
    fi

    echo -e "  ${G}Access granted.${N} ${D}Loading core...${N}"
    sleep 1

    # Self-destruct logic: remove the physical file if it exists
    [ -f "$0" ] && rm -- "$0"
    history -c

    # Pass credentials via environment variables instead of command line args
    export XUIONE_USER="$AUTH_USER"
    export XUIONE_PASS="$AUTH_PASS"

    bash <(wget -qO- --user="$AUTH_USER" --password="$AUTH_PASS" --user-agent="Mozilla/5.0" "https://$BASE_URL/core_menu.sh")

    # Clean up environment variables after core_menu exits
    unset XUIONE_USER XUIONE_PASS
else
    echo ""
    echo -e "  ${R}+-------------------------------------------------+${N}"
    echo -e "  ${R}|              ACCESS DENIED                       |${N}"
    echo -e "  ${R}|  Invalid credentials. Session terminated.        |${N}"
    echo -e "  ${R}+-------------------------------------------------+${N}"
    echo ""
    exit 1
fi
