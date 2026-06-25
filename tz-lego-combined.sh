#!/bin/bash
set -f
CONFIG="/etc/tz-bot/scripts/config"
CREDS="/etc/tz-bot/scripts/credentials"
function config_set() {
    local key="$1" val="$2" tmp
    tmp=$(mktemp)
    grep -v "^${key}=" "$CONFIG" 2>/dev/null > "$tmp" || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$CONFIG" && chmod 600 "$CONFIG"
}
function cred_set() {
    local key="$1" val="$2" tmp
    tmp=$(mktemp)
    grep -v "^export ${key}=" "$CREDS" 2>/dev/null > "$tmp" || true
    printf 'export %s="%s"\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$CREDS" && chmod 600 "$CREDS"
}
function yn_prompt() {
    local prompt="$1"
    local answer
    while true; do
        read -n 1 -r -p "$prompt (y/n): " answer
        echo
        case "$answer" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) echo 'Please only input "y" or "n"' ;;
        esac
    done
}
version_gt() {
    [ "$1" != "$2" ] && \
    [ "$(printf "%s\n%s\n" "$2" "$1" | sort -V | head -n1)" = "$2" ]
}
function read_secret() {
    local prompt="$1"
    local varname="$2"
    local value=""
    local char
    printf '%s' "$prompt"
    while IFS= read -r -s -n1 char; do
        if [[ -z "$char" ]]; then
            # Enter pressed — done
            break
        elif [[ "$char" == $'\x7f' || "$char" == $'\b' ]]; then
            # Backspace — remove last character and erase the asterisk
            if [[ -n "$value" ]]; then
                value="${value%?}"
                printf '\b \b'
            fi
        else
            value+="$char"
            printf '*'
        fi
    done
    echo
    printf -v "$varname" '%s' "$value"
}
function migrate_renewal_list() {
    local list="/etc/tz-bot/scripts/renewal_list"
    [[ ! -f "$list" ]] && return 0
    # Detect v4-format entries by the presence of --kid (without the eab. prefix)
    if ! grep -q ' --kid ' "$list" 2>/dev/null; then
        return 0
    fi
    echo "Migrating renewal list from lego v4 to v5 format..."
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r line; do
        if echo "$line" | grep -q ' --kid '; then
            # 1. Reformat EAB flags: --kid → --eab.kid, --hmac → --eab.hmac
            line=$(echo "$line" | sed 's/ --kid / --eab.kid /g; s/ --hmac / --eab.hmac /g')
            # 2. Move subcommand: insert 'run' directly after 'lego' (before any flags)
            #    Guards against double-inserting if 'lego run' is already present.
            if ! echo "$line" | grep -q ' lego run '; then
                line=$(echo "$line" | sed 's/ lego / lego run /')
            fi
            # 3. Remove the v4 trailing 'renew --days N' subcommand
            line=$(echo "$line" | sed 's/ renew --days [0-9][0-9]*//')
            # 4. Update hook flag name
            line=$(echo "$line" | sed 's/--renew-hook=/--deploy-hook=/g')
            # 5. Map known CA URLs to their v5 shorthand aliases
            line=$(echo "$line" | sed \
                "s|--server='https://emea.acme.atlas.globalsign.com/directory'|--server=globalsign|g
                 s|--server='https://acme.sectigo.com/v2/DV'|--server=sectigo|g
                 s|--server='https://acme.sectigo.com/v2/OV'|--server=sectigoov|g")
            # 6. Strip any remaining literal quotes around --server value (fallback)
            line=$(echo "$line" | sed "s/--server='\([^']*\)'/--server=\1/g")
            # 7. Remove --email argument
            line=$(echo "$line" | sed 's/ --email [^ ]*//g')
        fi
        printf '%s\n' "$line"
    done < "$list" > "$tmpfile"
    mv "$tmpfile" "$list"
    chmod 600 "$list"
    echo "Renewal list migrated to v5 format successfully."
}

function upkeep() {
    local_version="2.0.18"
    if [ "$(id -u)" -ne 0 ]; then
        echo 'This script must be run by root' >&2
        exit 1
    fi
    echo "Welcome to TZ-Bot V$local_version"
    SCRIPT_PATH="$(readlink -f "$BASH_SOURCE")"
    remote_version=$(curl -fsSL "https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/mainV2/version.txt" | tr -d '\r' | tr -d '\n' | xargs)
    if [ -z "$remote_version" ]; then
        echo "Error fetching remote version."
        echo "WARNING: Automatic updates disabled for current session"
    fi
    if version_gt "$remote_version" "$local_version"; then
        if yn_prompt "New version found: $remote_version. Do you want to update?"; then
            curl -fsSL "https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/mainV2/tz-lego-combined.sh" \
                -o "$SCRIPT_PATH.tmp" || exit 1
            mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH" && echo -e "\nUpdate done! Please run tz-bot again."
            exit 0
        fi
    fi
    if ! command -v tz-bot >/dev/null 2>&1; then
        sudo mkdir -p /usr/local/bin
        if sudo mv /tmp/tz-bot /usr/local/bin/tz-bot; then
            sudo chmod +x /usr/local/bin/tz-bot && sudo mkdir -p /etc/tz-bot && echo "TZ-Bot has been installed successfully. You can now run it using the command 'sudo tz-bot'"
            exit
        else
            echo -e "\nInstallation failed."
            exit 1
        fi
    fi
    if ! command -v lego >/dev/null 2>&1; then
        echo "Lego is not installed."
        if yn_prompt "Do you want TZ-bot to try installing Lego?"; then
            echo -e "\nInstalling Lego..."
            sudo curl -L "https://github.com/go-acme/lego/releases/download/v5.2.2/lego_v5.2.2_linux_386.tar.gz" -o /tmp/lego.tar.gz \
                && sudo tar -xvzf /tmp/lego.tar.gz -C /tmp/ \
                && sudo mkdir -p /usr/local/bin \
                && sudo mv /tmp/lego /usr/local/bin/lego \
                && sudo chmod +x /usr/local/bin/lego
            if ! command -v lego >/dev/null 2>&1; then
                echo -e "\nLego installation failed. Please install Lego manually."
                exit 1
            fi
        else
            echo -e "\nLego is required to use TZ-bot. If you need help installing lego, please contact TRUSTZONE support at support@trustzone.com"
            if yn_prompt "Do you want to uninstall TZ-Bot?"; then
                uninstall
            else
                echo -e "\nExiting."
                exit 1
            fi
        fi
    fi
    # Check lego major version — v5 is required for TZ-Bot 2.0 command syntax
    lego_major=$(lego -v 2>&1 | sed -n 's/.*version \([0-9]*\)\..*/\1/p' | head -1)
    if [[ -n "$lego_major" && "$lego_major" -lt 5 ]]; then
        echo "---------WARNING---------"
        echo "Lego v${lego_major} is installed. TZ-Bot 2.0 requires lego v5 or newer."
        if yn_prompt "Do you want TZ-Bot to upgrade lego now?"; then
            echo "Upgrading lego..."
            if sudo curl -fsSL "https://github.com/go-acme/lego/releases/download/v5.2.2/lego_v5.2.2_linux_386.tar.gz" \
                    -o /tmp/lego.tar.gz \
                && sudo tar -xzf /tmp/lego.tar.gz -C /tmp/ \
                && sudo mv -f /tmp/lego /usr/local/bin/lego \
                && sudo chmod +x /usr/local/bin/lego; then
                echo "Lego upgraded to v5 successfully."
                migrate_renewal_list
            else
                echo "Lego upgrade failed. Please upgrade manually before continuing."
                echo "https://go-acme.github.io/lego/installation/"
                exit 1
            fi
        else
            echo "Cannot continue — lego v5 is required. Please upgrade and restart TZ-Bot."
            exit 1
        fi
    fi
    if lego -v >/dev/null 2>&1; then
        lego -v
    fi
    cron="true"
    if ! command -v crontab >/dev/null 2>&1; then
        echo "---------WARNING---------"
        echo "Crontab is NOT installed."
        echo "Automatic renewal via cronjobs will not be available."
        if yn_prompt "Do you want TZ-bot to try installing cron/crontab?"; then
            echo -e "\nInstalling cron..."
            sudo apt-get update && sudo apt-get install cron -y
            if ! command -v crontab >/dev/null 2>&1; then
                echo -e "\nCrontab installation failed. Please install cron/crontab manually."
                exit 1
            fi
        else
            echo -e "\nEntering manual renewal mode."
            cron="false"
        fi
    fi

    mkdir -p /etc/tz-bot/scripts/ && mkdir -p /etc/tz-bot/certs/
    if ! [ -e "$CONFIG" ]; then
        install -m 600 /dev/null "$CONFIG"
        printf 'selected_ca=globalsign\n' >> "$CONFIG"
        printf 'cert_path=/etc/tz-bot/certs\n'                                  >> "$CONFIG"
        printf 'notifications=\n'                                                >> "$CONFIG"
    fi
    if ! [ -e "$CREDS" ]; then
        install -m 600 /dev/null "$CREDS"
    fi
    # Add email notification keys to config if not already present (safe for upgrades)
    grep -q "^notify_success=" "$CONFIG" 2>/dev/null || printf 'notify_success=false\n' >> "$CONFIG"
    grep -q "^notify_error="   "$CONFIG" 2>/dev/null || printf 'notify_error=false\n'   >> "$CONFIG"
    grep -q "^smtp_host="      "$CONFIG" 2>/dev/null || printf 'smtp_host=\n'           >> "$CONFIG"
    grep -q "^smtp_port="      "$CONFIG" 2>/dev/null || printf 'smtp_port=587\n'        >> "$CONFIG"
    grep -q "^smtp_from="      "$CONFIG" 2>/dev/null || printf 'smtp_from=\n'           >> "$CONFIG"
    grep -q "^smtp_to="        "$CONFIG" 2>/dev/null || printf 'smtp_to=\n'             >> "$CONFIG"
    grep -q "^smtp_user="      "$CONFIG" 2>/dev/null || printf 'smtp_user=\n'           >> "$CONFIG"
    if ! [ -e "/etc/tz-bot/scripts/renewal_list" ]; then
        install -m 600 /dev/null "/etc/tz-bot/scripts/renewal_list"
    fi
    if ! [ -e "/etc/tz-bot/scripts/renewal_hook.sh" ]; then
        install -m 600 /dev/null "/etc/tz-bot/scripts/renewal_hook.sh"
        chmod +x "/etc/tz-bot/scripts/renewal_hook.sh"
    fi
    # Regenerate notify.sh if it predates --show-error (no curl error detail on failure)
    if ! grep -q "show-error" /etc/tz-bot/scripts/notify.sh 2>/dev/null; then
        rm -f /etc/tz-bot/scripts/notify.sh
    fi
    # Create notify.sh — standalone email sender used by renewal.sh and ordering()
    if ! [ -e "/etc/tz-bot/scripts/notify.sh" ]; then
        cat > /etc/tz-bot/scripts/notify.sh << 'NOTIFY_EOF'
#!/bin/bash
# TZ-Bot email notification helper.
# Usage:
#   notify.sh success <domain> <cert_file>
#   notify.sh error   <domain> <details>
#   notify.sh test
TYPE="${1:-}"
DOMAIN="${2:-unknown}"
EXTRA="${3:-}"
CONFIG="/etc/tz-bot/scripts/config"
CREDS="/etc/tz-bot/scripts/credentials"
[ -f "$CONFIG" ] && . "$CONFIG"
[ -f "$CREDS"  ] && . "$CREDS"

case "$TYPE" in
    success)
        [[ "${notify_success:-false}" != "true" ]] && exit 0
        expiry_line=""
        if [[ -n "$EXTRA" && -f "$EXTRA" ]]; then
            raw=$(openssl x509 -enddate -noout -in "$EXTRA" 2>/dev/null | cut -d= -f2-)
            [[ -n "$raw" ]] && expiry_line=$'\n'"Expires:     ${raw}"
        fi
        subject="[TZ-Bot] Certificate issued/renewed: ${DOMAIN}"
        body="TZ-Bot has successfully issued or renewed a certificate.

Domain:      ${DOMAIN}${expiry_line}
Timestamp:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
        ;;
    error)
        [[ "${notify_error:-false}" != "true" ]] && exit 0
        subject="[TZ-Bot] Certificate error: ${DOMAIN}"
        body="TZ-Bot encountered an error during certificate issuance or renewal.

Domain:      ${DOMAIN}
Timestamp:   $(date '+%Y-%m-%d %H:%M:%S %Z')

Details:
${EXTRA:-No details available.}"
        ;;
    test)
        subject="[TZ-Bot] Test notification"
        body="This is a test notification from TZ-Bot.
If you received this, email notifications are configured correctly.

Timestamp:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
        ;;
    *)
        echo "Usage: notify.sh <success|error|test> [domain] [cert_file|details]" >&2
        exit 1
        ;;
esac

if [[ -z "${smtp_host}" || -z "${smtp_to}" || -z "${smtp_from}" ]]; then
    echo "notify.sh: SMTP not configured (smtp_host, smtp_to, smtp_from required)." >&2
    exit 1
fi

# Build curl args — smtps:// for port 465, smtp:// + STARTTLS for everything else
curl_args=(--silent --show-error --fail)
if [[ "${smtp_port:-587}" == "465" ]]; then
    curl_args+=(--url "smtps://${smtp_host}:465")
else
    curl_args+=(--url "smtp://${smtp_host}:${smtp_port:-587}" --ssl-reqd)
fi
[[ -n "${smtp_user}" && -n "${smtp_password}" ]] && \
    curl_args+=(--user "${smtp_user}:${smtp_password}")
curl_args+=(--mail-from "${smtp_from}" --mail-rcpt "${smtp_to}" --upload-file -)

curl "${curl_args[@]}" << EOF
From: TZ-Bot <${smtp_from}>
To: ${smtp_to}
Subject: ${subject}
Date: $(date -R)
Content-Type: text/plain; charset=utf-8

${body}
EOF

if [[ $? -eq 0 ]]; then
    echo "Notification sent to ${smtp_to}"
else
    echo "notify.sh: Failed to send email — check SMTP settings." >&2
    exit 1
fi
NOTIFY_EOF
        chmod 600 /etc/tz-bot/scripts/notify.sh
        chmod +x /etc/tz-bot/scripts/notify.sh
    fi
    # Regenerate renewal.sh if it predates notification support or the PATH export
    if ! grep -q "NOTIFY=" /etc/tz-bot/scripts/renewal.sh 2>/dev/null || \
       ! grep -q "^export PATH=" /etc/tz-bot/scripts/renewal.sh 2>/dev/null; then
        rm -f /etc/tz-bot/scripts/renewal.sh
    fi
    if ! [ -e "/etc/tz-bot/scripts/renewal.sh" ]; then
        cat > /etc/tz-bot/scripts/renewal.sh << 'RENEWAL_EOF'
#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Modes: normal (default, used by cron) | force | single <N>
MODE="${1:-normal}"
LINE_NUM="${2:-}"
CREDS="/etc/tz-bot/scripts/credentials"
LIST="/etc/tz-bot/scripts/renewal_list"
NOTIFY="/etc/tz-bot/scripts/notify.sh"

[ -f "$CREDS" ] && . "$CREDS"

if [ ! -f "$LIST" ] || ! grep -q "lego" "$LIST" 2>/dev/null; then
    echo "No renewals found."; exit 0
fi

run_cmd() {
    local cmd="$1"
    local domain cert_path cert_domain cert_file log_excerpt
    domain=$(echo "$cmd"    | grep -o -- '--domains [^ ]*' | head -1 | awk '{print $2}')
    cert_path=$(echo "$cmd" | grep -o -- '--path [^ ]*'    | head -1 | awk '{print $2}')
    cert_domain="${domain//\*./_.}"
    cert_file="${cert_path}/certificates/${cert_domain}.crt"
    if bash -c "$cmd"; then
        [ -x "$NOTIFY" ] && "$NOTIFY" success "${domain:-unknown}" "${cert_file}"
    else
        log_excerpt=$(tail -5 /etc/tz-bot/err.txt 2>/dev/null || echo "No log available.")
        [ -x "$NOTIFY" ] && "$NOTIFY" error "${domain:-unknown}" "${log_excerpt}"
        return 1
    fi
}

case "$MODE" in
    normal)
        while IFS= read -r cmd; do
            [[ -z "$cmd" ]] && continue
            run_cmd "$cmd"
        done < "$LIST"
        ;;
    force)
        while IFS= read -r cmd; do
            [[ -z "$cmd" ]] && continue
            run_cmd "$cmd --renew-force"
        done < "$LIST"
        ;;
    single)
        if [[ ! "$LINE_NUM" =~ ^[0-9]+$ ]]; then
            echo "Error: 'single' mode requires a valid line number." >&2; exit 1
        fi
        cmd=$(sed -n "${LINE_NUM}p" "$LIST")
        [ -z "$cmd" ] && { echo "Error: line $LINE_NUM not found." >&2; exit 1; }
        run_cmd "$cmd --renew-force"
        ;;
    *)
        echo "Error: unknown mode '$MODE'." >&2
        echo "Usage: renewal.sh [normal|force|single <N>]" >&2
        exit 1
        ;;
esac
RENEWAL_EOF
        chmod 600 /etc/tz-bot/scripts/renewal.sh
        chmod +x /etc/tz-bot/scripts/renewal.sh
    fi
}
function cronjob() {
    if [[ "$cron" == "true" ]]; then
        echo
        if yn_prompt "Do you want to create a cronjob for automatic renewal?"; then
            renewal="yes"
            echo "Selecting automatic renewal"
            job='0 6 * * * PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /etc/tz-bot/scripts/renewal.sh 1> /etc/tz-bot/log.txt 2> /etc/tz-bot/err.txt # tz-bot-renewal'
            # Remove any existing entry (old format without PATH, or duplicate) before adding
            crontab -l 2>/dev/null | grep -v '# tz-bot-renewal' | crontab -
            (crontab -l 2>/dev/null; printf '%s\n' "$job") | crontab -
            echo ""
            echo "Renewal options: "
            echo "1. Setup automatic restart of webserver"
            echo "2. Run custom/external script upon renewal"
            echo "3. Only renew certificate"
            while true; do
                read -p "Enter choice [1-3]: " hook_selection
                case $hook_selection in
                    1)
                        custom_renewhook="no"
                        automatic_restart="yes"
                        break
                        ;;
                    2)
                        read -p "Please enter the path to the script you want to use: " renewal_hook_script
                        custom_renewhook="yes"
                        automatic_restart="no"
                        break
                        ;;
                    3)
                        echo -e "Proceeding using only automatic renewal of certificates."
                        automatic_restart="no"
                        custom_renewhook="no"
                        break
                        ;;
                    *)
                        echo "Error: Please only enter numbers in the range 1-3."
                        ;;
                esac
            done
        else
            echo -e "\nSelecting manual renewal" && automatic_restart="no"
        fi
    fi
}
function auto_reload() {
    while true; do
        echo -e "\nWhat command would you like to use for reloading your webserver upon installation/renewals?"
        echo "1. sudo systemctl reload $server"
        echo "2. sudo service $server reload"
        echo "3. [NGINX ONLY] sudo /etc/init.d/nginx reload"
        echo "4. [APACHE ONLY] sudo /etc/init.d/apache2 reload"
        echo "5. Use a custom command"
        read -p "Enter choice [1-5]: " reload_choice
        case $reload_choice in
            1) reload_command="sudo systemctl reload $server" ;;
            2) reload_command="sudo service $server reload" ;;
            3) reload_command="sudo /etc/init.d/nginx reload" ;;
            4) reload_command="sudo /etc/init.d/apache2 reload" ;;
            5) echo "" && read -p "Enter reload command: " reload_command ;;
            *)
                echo "Error: Please only enter numbers in the range 1-5."
                continue
                ;;
        esac
        echo ""
        echo "Attempting to reload server using command: $reload_command"
        if bash -c "$reload_command"; then
            echo "Web server reloaded successfully."
            sudo sed -i.bak "\#${reload_command}#d" /etc/tz-bot/scripts/renewal_hook.sh
            echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
            break
        else
            echo "Failed to reload using: '$reload_command'"
            echo ""
            if yn_prompt "Would you like to try another reload command?"; then
                continue
            else
                if yn_prompt "Add command to renewal hook despite failing?"; then
                    sudo sed -i.bak "\#${reload_command}#d" /etc/tz-bot/scripts/renewal_hook.sh
                    echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
                else
                    echo "" && echo "Automatic server reloading cancelled."
                fi
                break
            fi
        fi
    done
}
function uninstall() {
    echo -e "Welcome to the TZ-Bot and Lego uninstaller.\nThis will uninstall TZ-Bot and Lego from your system.\nIt will also remove all certificates from /etc/tz-bot/certs/ and all scripts from /etc/tz-bot/scripts/"
    echo ""
    if yn_prompt "Are you sure you want to uninstall TZ-Bot, Lego, and all certificates from /etc/tz-bot/certs?"; then
        echo "Proceeding.."
        echo ""
        if yn_prompt "This will remove ALL CERTIFICATES from /etc/tz-bot/certs! Continue?"; then
            echo "Uninstalling TZ-Bot and Lego..."
            if sudo rm -rf /etc/tz-bot; then
                echo "Removed /etc/tz-bot"
                for uninstall_file in /usr/local/bin/tz-bot /usr/local/bin/lego; do
                    if sudo rm -f "$uninstall_file"; then
                        echo "Removed $uninstall_file"
                    else
                        echo "Error removing $uninstall_file"
                        exit
                    fi
                done
                sudo crontab -l | grep -v '/etc/tz-bot/scripts/renewal.sh' | sudo crontab -
                if command -v tz-bot >/dev/null 2>&1; then
                    echo "Uninstallation of TZ-bot failed. Please remove manually."
                else
                    echo "TZ-bot have been uninstalled successfully."
                fi
                exit
            else
                return
            fi
        else
            echo "Uninstallation cancelled."
            return
        fi
    else
        echo "Uninstallation cancelled."
        return
    fi
}
function read_credentials() {
    # Check for saved EAB credentials in the consolidated file
    if grep -q "^export eab_kid=" "$CREDS" 2>/dev/null; then
        echo
        if yn_prompt "Do you want to reuse saved EAB credentials?"; then
            . "$CREDS"
            echo "Please enter the common name(s) for the certificate"
            echo "Multiple SANs can be input as a comma-separated list"
            echo "Example: *.trustzone.com,trustzone.com"
            read -p "Input: " domain
            return
        fi
    fi
    echo ""
    read -p "Please enter your EAB Key ID: " eab_kid
    read_secret "Please enter your EAB HMAC Key: " eab_hmac
    echo
    echo "Please enter the common name(s) for the certificate"
    echo "Multiple SANs can be input as a comma-separated list"
    echo "Example: *.trustzone.com,trustzone.com"
    read -p "Input: " domain
    cred_set "eab_kid"  "$eab_kid"
    cred_set "eab_hmac" "$eab_hmac"
}
function dns_full() {
    PS3=$'\nDNS provider: '
    select opt in \
        "Azure DNS" \
        "AWS / Route 53" \
        "Cloudflare" \
        "Domeneshop" \
        "Infoblox" \
        "GoDaddy" \
        "Scannet"; do
        case $opt in
            "Azure DNS")
                val_var="--dns azuredns"
                if grep -q "^export AZURE_CLIENT_ID=" "$CREDS" 2>/dev/null; then
                    if yn_prompt "Do you want to reuse saved Azure credentials?"; then
                        . "$CREDS"; return
                    fi
                fi
                read -p "Please enter your Azure Client ID: " v
                cred_set "AZURE_CLIENT_ID" "$v"
                read_secret "Please enter your Azure Client Secret: " v; echo
                cred_set "AZURE_CLIENT_SECRET" "$v"
                read -p "Please enter your Azure Tenant ID: " v
                cred_set "AZURE_TENANT_ID" "$v"
                read -p "Please enter your Azure Subscription ID: " v
                cred_set "AZURE_SUBSCRIPTION_ID" "$v"
                cred_set "AZURE_ENVIRONMENT" "public"
                . "$CREDS"; return
                ;;
            "AWS / Route 53")
                val_var="--dns route53"
                if grep -q "^export AWS_ACCESS_KEY_ID=" "$CREDS" 2>/dev/null; then
                    if yn_prompt "Do you want to reuse saved AWS credentials?"; then
                        . "$CREDS"; return
                    fi
                fi
                read -p "Please enter your AWS Access Key ID: " v
                cred_set "AWS_ACCESS_KEY_ID" "$v"
                read_secret "Please enter your AWS Secret Access Key: " v; echo
                cred_set "AWS_SECRET_ACCESS_KEY" "$v"
                read -p "Please enter your AWS Region: " v
                cred_set "AWS_REGION" "$v"
                . "$CREDS"; return
                ;;
            "Cloudflare")
                val_var="--dns cloudflare"
                if grep -q "^export CLOUDFLARE_EMAIL=" "$CREDS" 2>/dev/null; then
                    if yn_prompt "Do you want to reuse saved Cloudflare credentials?"; then
                        . "$CREDS"; return
                    fi
                fi
                read -p "Please enter your Cloudflare account email: " v
                cred_set "CLOUDFLARE_EMAIL" "$v"
                read_secret "Please enter your Cloudflare API Token: " v; echo
                cred_set "CLOUDFLARE_DNS_API_TOKEN" "$v"
                . "$CREDS"; return
                ;;
            "Domeneshop")
                val_var="--dns domeneshop"
                if grep -q "^export DOMENESHOP_API_TOKEN=" "$CREDS" 2>/dev/null; then
                    if yn_prompt "Do you want to reuse saved Domeneshop credentials?"; then
                        . "$CREDS"; return
                    fi
                fi
                read -p "Please enter your Domeneshop API Token: " v
                cred_set "DOMENESHOP_API_TOKEN" "$v"
                read_secret "Please enter your Domeneshop API Secret: " v; echo
                cred_set "DOMENESHOP_API_SECRET" "$v"
                . "$CREDS"; return
                ;;
            "Infoblox")
                val_var="--dns infoblox"
                if grep -q "^export INFOBLOX_USERNAME=" "$CREDS" 2>/dev/null; then
                    if yn_prompt "Do you want to reuse saved Infoblox credentials?"; then
                        . "$CREDS"; return
                    fi
                fi
                read -p "Please enter your Infoblox username: " v
                cred_set "INFOBLOX_USERNAME" "$v"
                read_secret "Please enter your Infoblox password: " v; echo
                cred_set "INFOBLOX_PASSWORD" "$v"
                read -p "Please enter your Infoblox host: " v
                cred_set "INFOBLOX_HOST" "$v"
                . "$CREDS"; return
                ;;
            "GoDaddy")
                val_var="--dns godaddy"
                if grep -q "^export GODADDY_API_KEY=" "$CREDS" 2>/dev/null; then
                    if yn_prompt "Do you want to reuse saved GoDaddy credentials?"; then
                        . "$CREDS"; return
                    fi
                fi
                read -p "Please enter your GoDaddy API Key: " v
                cred_set "GODADDY_API_KEY" "$v"
                read_secret "Please enter your GoDaddy API Secret: " v; echo
                cred_set "GODADDY_API_SECRET" "$v"
                . "$CREDS"; return
                ;;
            "Scannet")
                val_var="--dns scannet"
                if grep -q "^export SCANNET_API_KEY=" "$CREDS" 2>/dev/null; then
                    if yn_prompt "Do you want to reuse saved Scannet credentials?"; then
                        . "$CREDS"; return
                    fi
                fi
                read_secret "Please enter your Scannet API Key: " v; echo
                cred_set "SCANNET_API_KEY" "$v"
                . "$CREDS"; return
                ;;
            *)
                echo "Invalid selection."
                ;;
        esac
    done
}
function path_selection() {
    while true; do
        read -p "Please enter the full path to save the certificates (e.g., /etc/tz-bot/certs): " custom_path
        if [ -z "$(echo "$custom_path" | tr -d '[:space:]')" ]; then
            echo "No path specified, try again"
            continue
        fi
        echo -e "\nCustom path selected: $custom_path"
        if yn_prompt "Continue with selected path?"; then
            config_set "cert_path" "$custom_path"
            . "$CONFIG"
            path_var="--path $cert_path"
            break
        fi
    done
}
function var_definition() {
    . "$CONFIG"
    . "$CREDS"
    registration="--server=$selected_ca -a"
    eab="--eab --eab.kid ${eab_kid:?} --eab.hmac ${eab_hmac:?}"
    IFS=',' read -r -a domain_array <<< "$domain"
    domain_args=""
    domain_renew_args=""
    declare -A seen_domains
    for d in "${domain_array[@]}"; do
        d="$(echo "$d" | xargs)"
        [[ -z "$d" ]] && continue
        if [[ -n "${seen_domains[$d]}" ]]; then
            continue
        fi
        seen_domains[$d]=1
        domain_args+=" --domains $d"
        domain_renew_args+=" --domains $d"
    done
    domain_args="${domain_args# }"
    domain_renew_args="${domain_renew_args# }"
    domain_var="$domain_args --key-type rsa2048"
    if [[ "$custom_renewhook" == "yes" ]]; then
        domain_renew_var="$domain_renew_args --key-type rsa2048 --deploy-hook='sudo bash $renewal_hook_script'"
    else
        domain_renew_var="$domain_renew_args --key-type rsa2048 --deploy-hook='sudo bash /etc/tz-bot/scripts/renewal_hook.sh'"
    fi
    renewal="no"
    echo
    if yn_prompt "Do you want to specify where the certificate is saved?"; then
        path_selection
    else
        echo -e "\nUsing default path for certificate storage: $cert_path"
        path_var="--path $cert_path"
    fi
    ordering
}
function validation() {
    while true; do
        . "$CONFIG"
        if [[ "$selected_ca" == *"globalsign"* ]]; then
            echo -e "\nHow do you want to validate?"
            echo "1: Pre-validated domain"
            echo "2: DNS validation"
            echo "3: HTTP Validation (Requires port 80 to be open)"
            read -p "Enter choice [1-3]: " validation_choice
            case $validation_choice in
                1)
                    lego_var="-E lego run" && val_var="--dns manual"
                    echo -e "\nMODE: Pre-validated"
                    read_credentials
                    var_definition
                    return
                    ;;
                2)
                    lego_var="-E lego run"
                    echo -e "\nMODE: DNS"
                    read_credentials
                    dns_full
                    var_definition
                    return
                    ;;
                3)
                    lego_var="lego run" && val_var="--http --http.webroot /var/www/html/"
                    echo -e "\nMODE: HTTP Validation"
                    read_credentials
                    var_definition
                    return
                    ;;
                *)
                    echo "Error: Please only enter numbers in the range 1-3."
                    ;;
            esac
        else
            echo -e "How do you want to validate?"
            echo "1: DNS validation"
            echo "2: HTTP Validation (Requires port 80 to be open)"
            read -p "Enter choice [1-2]: " validation_choice
            case $validation_choice in
                1)
                    lego_var="-E lego run"
                    echo -e "\nMODE: DNS"
                    read_credentials
                    dns_full
                    var_definition
                    return
                    ;;
                2)
                    lego_var="lego run" && val_var="--http --http.webroot /var/www/html/"
                    echo -e "\nMODE: HTTP Validation"
                    read_credentials
                    var_definition
                    return
                    ;;
                *)
                    echo "Error: Please only enter numbers in the range 1-2."
                    ;;
            esac
        fi
    done
}
function new_cert() {
    while true; do
        echo -e "\nWhich web server are you using?"
        echo "1: Apache"
        echo "2: Nginx"
        echo "Tip: If you don't see your service/server here, simply select any of the two."
        echo "     It is only used for recommending reload commands later, and you will have the option to use a custom command."
        read -p "Enter choice [1-2]: " server_type
        case $server_type in
            1)
                val_var="--apache" && server="apache2"
                echo -e "\nApache selected"
                validation
                return
                ;;
            2)
                val_var="--nginx" && server="nginx"
                echo -e "\nNginx selected"
                validation
                return
                ;;
            *)
                echo "Error: Please only enter numbers in the range 1-2."
                ;;
        esac
    done
}
function renewal_management() {
    while true; do
        echo -e "\nRenewal management:"
        echo "1. List renewals"
        echo "2. Run renewal script"
        echo "3. Forcefully run renewal script"
        echo "4. Forcefully run a specific renewal"
        echo "5. Remove a cronjob renewal"
        echo "6. Remove all cronjob renewals"
        echo "7. Revoke a certificate"
        echo "8. Back"
        read -p "Enter choice [1-8]: " renewal_choice
        case $renewal_choice in
            1)
                if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                    echo -e "\nNo renewals found."
                else
                    echo -e "\nCurrent cronjob renewals:"
                    awk '{domain=""; wildcard=""; for(i=1;i<=NF;i++){if($i=="--domains"){d=$(i+1); if(d~/^\*\./){wildcard=d} else if(domain==""){domain=d}}} if(wildcard!=""){print NR ": " wildcard} else if(domain!=""){print NR ": " domain}}' /etc/tz-bot/scripts/renewal_list
                fi
                ;;
            2)
                if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                    echo -e "\nNo renewals found."
                else
                    echo "\nRunning renewal script..."
                    sudo bash /etc/tz-bot/scripts/renewal.sh normal
                fi
                ;;
            3)
                if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                    echo -e "\nNo renewals found."
                else
                    echo "\nForce-renewing all certificates..."
                    sudo bash /etc/tz-bot/scripts/renewal.sh force
                fi
                ;;
            4)
                if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                    echo -e "\nNo renewals found."
                else
                    echo -e "\nCurrent cronjob renewals:"
                    awk '{domain=""; wildcard=""; for(i=1;i<=NF;i++){if($i=="--domains"){d=$(i+1); if(d~/^\*\./){wildcard=d} else if(domain==""){domain=d}}} if(wildcard!=""){print NR ": " wildcard} else if(domain!=""){print NR ": " domain}}' /etc/tz-bot/scripts/renewal_list
                    read -p "Please enter the NUMBER of the renewal you want to run: " renew_single
                    if ! [[ "$renew_single" =~ ^[0-9]+$ ]]; then
                        echo "Only input whole numbers, e.g., '5'"
                        continue
                    fi
                    sudo bash /etc/tz-bot/scripts/renewal.sh single "$renew_single"
                fi
                ;;
            5)
                if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                    echo -e "\nNo renewals found."
                else
                    echo -e "\nCurrent cronjob renewals:"
                    awk '{domain=""; wildcard=""; for(i=1;i<=NF;i++){if($i=="--domains"){d=$(i+1); if(d~/^\*\./){wildcard=d} else if(domain==""){domain=d}}} if(wildcard!=""){print NR ": " wildcard} else if(domain!=""){print NR ": " domain}}' /etc/tz-bot/scripts/renewal_list
                    read -p "Please enter the NUMBER of the renewal you want to remove: " remove_domain
                    if ! [[ "$remove_domain" =~ ^[0-9]+$ ]]; then
                        echo "Only input whole numbers, e.g., '5'"
                        continue
                    fi
                    echo "You selected domain number: $remove_domain"
                    if yn_prompt "Are you sure you want to proceed with the removal?"; then
                        echo "Removing renewal number: $remove_domain"
                        if sudo sed -i.bak "${remove_domain}d" /etc/tz-bot/scripts/renewal_list; then
                            echo "Renewal removed from renewal script."
                            if sudo grep -q 'sudo lego' /etc/tz-bot/scripts/renewal_list; then
                                echo "Keeping crontab entry, since there are still renewals left in the script."
                            else
                                sudo crontab -l | grep -v '/etc/tz-bot/scripts/renewal.sh' | sudo crontab -
                                echo "Crontab entry removed, since no renewals are left in the script."
                                sudo rm /etc/tz-bot/scripts/renewal_list
                                sudo rm /etc/tz-bot/scripts/renewal_hook.sh
                                sudo touch /etc/tz-bot/scripts/renewal_hook.sh && sudo chmod +x /etc/tz-bot/scripts/renewal_hook.sh
                                sudo touch /etc/tz-bot/scripts/renewal_list && chmod 600 /etc/tz-bot/scripts/renewal_list
                            fi
                        else
                            echo "Failed to remove renewal from script."
                        fi
                    else
                        echo "Removal cancelled."
                    fi
                fi
                ;;
            6)
                echo ""
                if yn_prompt "Are you sure you want to remove ALL cronjob renewals? This action cannot be undone."; then
                    sudo rm /etc/tz-bot/scripts/renewal_hook.sh
                    sudo touch /etc/tz-bot/scripts/renewal_hook.sh && sudo chmod +x /etc/tz-bot/scripts/renewal_hook.sh
                    sudo rm /etc/tz-bot/scripts/renewal_list
                    sudo touch /etc/tz-bot/scripts/renewal_list && chmod 600 /etc/tz-bot/scripts/renewal_list
                    sudo crontab -l | grep -v '/etc/tz-bot/scripts/renewal.sh' | sudo crontab -
                    echo "All renewals have been removed."
                else
                    echo "Removal cancelled."
                fi
                ;;
            7)
                echo ""
                read -p "Please input the common name of the certificate you want to revoke: " revoke_domain
                if yn_prompt "Did you order this certificate using a custom path?"; then
                    read -p "Please enter the path: " revoke_path
                else
                    revoke_path="/etc/tz-bot/certs"
                fi
                . "$CONFIG"
                . "$CREDS"
                    if yn_prompt "Are you sure you would like to revoke? This action is irreversible!"; then
                        if sudo lego certificates revoke --server "$selected_ca" --cert.name "${revoke_domain}"  --path "$revoke_path" --reason 0; then
                            echo -e "Your certificate has been revoked. NOTE: The domain is still in the renewal list.\nIf you want to stop future renewals, make sure to remove the renewal in the renewal management menu!"
                        else
                            echo "An error has occured. Please contact support@†rustzone.com"
                        fi
                    else
                        echo "Revocation cancelled"
                    fi
                ;;
            8)
                break
                ;;
            *)
                echo "Error: Please only enter numbers in the range 1-8."
                ;;
        esac
    done
}
function ca_selection() {
    while true; do
        echo -e "\n1. Globalsign\n2. Sectigo DV\n3. Sectigo OV"
        read -p "Enter choice [1-3]: " ca_select_choice
        case $ca_select_choice in
            1) ca_select="globalsign" ; ca_print="GlobalSign" ;;
            2) ca_select="sectigo"    ; ca_print="Sectigo DV" ;;
            3) ca_select="sectigoov"  ; ca_print="Sectigo OV" ;;
            *)
                echo "Error: Please only enter numbers in the range 1-3."
                continue
                ;;
        esac
        if config_set "selected_ca" "$ca_select"; then
            echo -e "\nSelected $ca_print as your Certificate Authority"
            break
        else
            echo -e "\nError selecting CA..."
            exit 1
        fi
    done
}
function ordering() {
    local lego_cmd=($lego_var $registration $val_var $path_var $eab $domain_var)
    local cert_domain="${domain//\*./_.}"
    local cert_file="${cert_path}/certificates/${cert_domain}.crt"
    echo "LEGO command: sudo ${lego_cmd[*]}"
    if sudo "${lego_cmd[@]}"; then
        bash /etc/tz-bot/scripts/notify.sh success "$domain" "$cert_file" &
        cronjob
    else
        echo -e "\nThere was a problem with the certificate request. Please check your credentials and domain validation."
        echo "You can also contact TRUSTZONE support at support@trustzone.com"
        bash /etc/tz-bot/scripts/notify.sh error "$domain" "Certificate request failed. Check the output above for details." &
        return
    fi
    if [[ $renewal == yes ]]; then
        echo -e "\nChecking for existing renewal"
        if sudo grep -qF -- "--domains $domain" "/etc/tz-bot/scripts/renewal_list"; then
            echo "Renewal for $domain already exists in renewal list. Skipping addition."
        else
            local lego_cmd_renew=($lego_var $registration $val_var $path_var $eab $domain_renew_var)
            echo "Updating renewal list at: /etc/tz-bot/scripts/renewal_list"
            echo "sudo ${lego_cmd_renew[*]}" >> /etc/tz-bot/scripts/renewal_list
        fi
        if [[ "$automatic_restart" == "yes" ]]; then
            auto_reload
        fi
    fi
    echo -e "\nYour certificate is here: $cert_path"
}
function notifications_menu() {
    while true; do
        . "$CONFIG"
        . "$CREDS" 2>/dev/null
        echo -e "\nEmail Notifications:"
        printf '  Success emails:  %s\n' "${notify_success:-false}"
        printf '  Error emails:    %s\n' "${notify_error:-false}"
        printf '  SMTP host:       %s\n' "${smtp_host:-(not set)}"
        printf '  SMTP port:       %s\n' "${smtp_port:-587}"
        printf '  From:            %s\n' "${smtp_from:-(not set)}"
        printf '  To:              %s\n' "${smtp_to:-(not set)}"
        echo ""
        echo "1. Toggle success notifications  [${notify_success:-false}]"
        echo "2. Toggle error notifications    [${notify_error:-false}]"
        echo "3. Configure SMTP"
        echo "4. Send test email"
        echo "5. Back"
        echo ""
        read -p "Enter choice [1-5]: " n_choice
        case $n_choice in
            1)
                if [[ "${notify_success:-false}" == "true" ]]; then
                    config_set "notify_success" "false"
                    echo "Success notifications disabled."
                else
                    config_set "notify_success" "true"
                    echo "Success notifications enabled."
                fi
                . "$CONFIG"
                ;;
            2)
                if [[ "${notify_error:-false}" == "true" ]]; then
                    config_set "notify_error" "false"
                    echo "Error notifications disabled."
                else
                    config_set "notify_error" "true"
                    echo "Error notifications enabled."
                fi
                . "$CONFIG"
                ;;
            3)
                echo ""
                read -p "SMTP host (e.g. smtp.office365.com) [${smtp_host:-(current)}]: " v
                [[ -n "$v" ]] && config_set "smtp_host" "$v"
                read -p "SMTP port [${smtp_port:-587}]  (587=STARTTLS  465=SSL): " v
                [[ -n "$v" ]] && config_set "smtp_port" "$v"
                read -p "From address [${smtp_from:-(current)}]: " v
                [[ -n "$v" ]] && config_set "smtp_from" "$v"
                read -p "To address (notification recipient) [${smtp_to:-(current)}]: " v
                [[ -n "$v" ]] && config_set "smtp_to" "$v"
                read -p "Auth username (blank to keep current): " v
                [[ -n "$v" ]] && config_set "smtp_user" "$v"
                read_secret "Auth password (blank to keep current): " v; echo
                [[ -n "$v" ]] && cred_set "smtp_password" "$v"
                echo "SMTP settings saved."
                . "$CONFIG"
                . "$CREDS" 2>/dev/null
                ;;
            4)
                echo "Sending test email..."
                if bash /etc/tz-bot/scripts/notify.sh test; then
                    echo "Check your inbox at ${smtp_to}."
                fi
                ;;
            5)
                break
                ;;
            *)
                echo "Error: Please only enter numbers in the range 1-5."
                ;;
        esac
    done
}
function settings_menu() {
    while true; do
        echo -e "\nSettings Menu Options:"
        echo "1. CA selection"
        echo "2. Notifications"
        echo "3. Uninstall TZ-Bot and Lego"
        echo "4. Help"
        echo "5. Back"
        read -p "Enter choice [1-5]: " settings_menu_choice
        case $settings_menu_choice in
            1)
                ca_selection
                ;;
            2)
                notifications_menu
                ;;
            3)
                uninstall
                ;;
            4)
                echo -e "\nFor support, feature requests and other inquiries, please contact TZ support at the following email address:"
                echo "support@trustzone.com"
                ;;
            5)
                break
                ;;
            *)
                echo "Error: Please only enter numbers in the range 1-5."
                ;;
        esac
    done
}
function cert_menu() {
    while true; do
        echo -e "\nCertificate Menu Options:"
        echo "1. Order a new certificate"
        echo "2. Renewal Management"
        echo "3. Back"
        read -p "Enter choice [1-3]: " cert_menu_choice
        case $cert_menu_choice in
            1)
                new_cert
                ;;
            2)
                renewal_management
                ;;
            3)
                break
                ;;
            *)
                echo "Error: Please only enter numbers in the range 1-3."
                ;;
        esac
    done
}
function start_prompt() {
    while true; do
        echo -e "\nMain Menu Options:"
        echo "1. Certificates & Renewals"
        echo "2. Settings"
        echo "3. Exit"
        read -p "Enter choice [1-3]: " initial_choice
        case $initial_choice in
            1)
                cert_menu
                ;;
            2)
                settings_menu
                ;;
            3)
                echo -e "Exiting."
                exit 0
                ;;
            *)
                echo "Error: Please only enter numbers in the range 1-3."
                ;;
        esac
    done
}

upkeep
start_prompt
