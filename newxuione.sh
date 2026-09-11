#!/bin/bash

# --- Configuration ---
BASE_URL="tealc.pw/stuff/xuione/new"

# FTP logging server
FTP_HOST="server112.web-hosting.com"
FTP_USER="tealcnewxuione@tealc.pw"
FTP_PASS="P2AbwHqdV3o3l5rVd5"
FTP_BASE="multitool"
MAX_IPS_24H=2

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
# FTP & IP TRACKING FUNCTIONS
# ============================================================

get_public_ip() {
    # Get both IPv4 and IPv6
    local ipv4="" ipv6=""
    ipv4=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    [ -z "$ipv4" ] && ipv4=$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null)
    ipv6=$(curl -6 -s --max-time 5 ifconfig.me 2>/dev/null)
    [ -z "$ipv6" ] && ipv6=$(curl -6 -s --max-time 5 api64.ipify.org 2>/dev/null)
    # If IPv6 is same as IPv4 (no real IPv6), clear it
    [ "$ipv6" == "$ipv4" ] && ipv6=""
    echo "${ipv4:-none}|${ipv6:-none}"
}

ftp_download() {
    local remote_path="$1"
    curl -s --max-time 10 "ftp://$FTP_HOST/$remote_path" \
        --user "$FTP_USER:$FTP_PASS" 2>/dev/null
}

ftp_upload() {
    local remote_path="$1"
    curl -s --max-time 10 -T - "ftp://$FTP_HOST/$remote_path" \
        --user "$FTP_USER:$FTP_PASS" --ftp-create-dirs 2>/dev/null
}

# File: multitool/{username}.log
# Format per line: timestamp|date|ipv4|ipv6|status|hostname|os
# Rate limiting counts unique IPs (v4 and v6 separately) in last 24h

check_and_log() {
    local username="$1" ipv4="$2" ipv6="$3" status="$4"
    local log_file="$FTP_BASE/${username}.log"
    local now date_str hostname_str os_str
    now=$(date -u +%s)
    date_str=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    hostname_str=$(hostname 2>/dev/null || echo "unknown")
    os_str=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "unknown")
    local cutoff=$((now - 86400))

    # Download existing log
    local existing
    existing=$(ftp_download "$log_file")

    # Count unique SOURCES from last 24h (only GRANTED entries)
    # A "source" = one server. IPv4+IPv6 from same login = 1 source.
    # A new login matches an existing source if ANY of its IPs (v4 or v6)
    # match ANY IP from that source's entry.
    # Example: Server A (v4=1.1.1.1, v6=2001::1) = source 1
    #          Server B (v4=2.2.2.2, v6=2001::2) = source 2
    #          Server A again (same v4 or v6)    = still source 1 (not new)
    local -a source_v4s=()     # IPv4 of each unique source
    local -a source_v6s=()     # IPv6 of each unique source
    local source_count=0
    local current_ip_registered=false

    if [ -n "$existing" ]; then
        while IFS='|' read -r ts dt v4 v6 st rest; do
            [ -z "$ts" ] && continue
            # Only check GRANTED entries within 24h
            if [ "$ts" -ge "$cutoff" ] 2>/dev/null && [[ "$st" == "GRANTED" ]]; then
                # Check if this entry matches an existing source
                local is_known_source=false
                for i in $(seq 0 $((source_count - 1))); do
                    # Match if v4 matches OR v6 matches
                    if [ "$v4" != "none" ] && [ "$v4" == "${source_v4s[$i]}" ]; then
                        is_known_source=true; break
                    fi
                    if [ "$v6" != "none" ] && [ "$v6" == "${source_v6s[$i]}" ]; then
                        is_known_source=true; break
                    fi
                done
                # New source
                if [ "$is_known_source" == "false" ]; then
                    source_v4s+=("$v4")
                    source_v6s+=("$v6")
                    source_count=$((source_count + 1))
                fi
                # Check if current login matches this entry
                if [ "$ipv4" != "none" ] && [ "$v4" != "none" ] && [ "$ipv4" == "$v4" ]; then
                    current_ip_registered=true
                fi
                if [ "$ipv6" != "none" ] && [ "$v6" != "none" ] && [ "$ipv6" == "$v6" ]; then
                    current_ip_registered=true
                fi
            fi
        done <<< "$existing"
    fi

    # Build new log entry
    local new_entry="${now}|${date_str}|${ipv4}|${ipv6}|${status}|${hostname_str}|${os_str}"

    # Check IP limit (only for GRANTED logins, and only when this server's public IP
    # was actually determined). If IP lookup failed (both none), fail OPEN so a
    # transient ifconfig.me/ipify outage can't wrongly lock out a legitimate user.
    if [ "$status" == "GRANTED" ] && { [ "$ipv4" != "none" ] || [ "$ipv6" != "none" ]; }; then
        if [ "$source_count" -ge "$MAX_IPS_24H" ] && [ "$current_ip_registered" == "false" ]; then
            # BLOCKED — log it and show error
            new_entry="${now}|${date_str}|${ipv4}|${ipv6}|BLOCKED|${hostname_str}|${os_str}"
            if [ -n "$existing" ]; then
                printf '%s\n%s\n' "$existing" "$new_entry" | ftp_upload "$log_file"
            else
                printf '%s\n' "$new_entry" | ftp_upload "$log_file"
            fi

            echo ""
            echo -e "  ${R}+-------------------------------------------------+${N}"
            echo -e "  ${R}|           IP LIMIT EXCEEDED                      |${N}"
            echo -e "  ${R}+-------------------------------------------------+${N}"
            echo ""
            echo -e "  ${Y}This account has reached the maximum of ${W}${MAX_IPS_24H}${Y} different${N}"
            echo -e "  ${Y}servers/IPs in the last 24 hours.${N}"
            echo ""
            echo -e "  ${W}Currently registered servers:${N}"
            for i in $(seq 0 $((source_count - 1))); do
                local disp=""
                [ "${source_v4s[$i]}" != "none" ] && disp="v4: ${source_v4s[$i]}"
                if [ "${source_v6s[$i]}" != "none" ]; then
                    [ -n "$disp" ] && disp="$disp  /  "
                    disp="${disp}v6: ${source_v6s[$i]}"
                fi
                echo -e "    ${C}$((i+1)).${N} ${W}${disp}${N}"
            done
            echo ""
            echo -e "  ${D}Your IPs:${N}"
            [ "$ipv4" != "none" ] && echo -e "    ${D}IPv4: ${ipv4}${N}"
            [ "$ipv6" != "none" ] && echo -e "    ${D}IPv6: ${ipv6}${N}"
            echo -e "  ${D}Please wait 24h or use one of the registered servers.${N}"
            echo ""
            return 1
        fi
    fi

    # Append new entry and upload
    if [ -n "$existing" ]; then
        printf '%s\n%s\n' "$existing" "$new_entry" | ftp_upload "$log_file"
    else
        printf '%s\n' "$new_entry" | ftp_upload "$log_file"
    fi
    return 0
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

    # Get both IPv4 and IPv6
    IP_RESULT=$(get_public_ip)
    PUBLIC_IPV4=$(echo "$IP_RESULT" | cut -d'|' -f1)
    PUBLIC_IPV6=$(echo "$IP_RESULT" | cut -d'|' -f2)

    if [ "$PUBLIC_IPV4" == "none" ] && [ "$PUBLIC_IPV6" == "none" ]; then
        echo -e "  ${Y}Note: could not determine this server's public IP; skipping the IP limit check.${N}"
    fi

    # Check IP limit + log
    if ! check_and_log "$AUTH_USER" "$PUBLIC_IPV4" "$PUBLIC_IPV6" "GRANTED"; then
        exit 1
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
    # Log failed login attempt
    IP_RESULT=$(get_public_ip)
    FAIL_IPV4=$(echo "$IP_RESULT" | cut -d'|' -f1)
    FAIL_IPV6=$(echo "$IP_RESULT" | cut -d'|' -f2)
    check_and_log "${AUTH_USER:-unknown}" "$FAIL_IPV4" "$FAIL_IPV6" "DENIED"

    echo ""
    echo -e "  ${R}+-------------------------------------------------+${N}"
    echo -e "  ${R}|              ACCESS DENIED                       |${N}"
    echo -e "  ${R}|  Invalid credentials. Session terminated.        |${N}"
    echo -e "  ${R}+-------------------------------------------------+${N}"
    echo ""
    exit 1
fi
