#!/bin/bash
set -f
function cronjob() {
    if cron="true"; then
        echo
        if yn_prompt "Do you want to create a cronjob for automatic renewal?"; then
            renewal="yes" 
            echo "Selecting automatic renewal"
            job='0 6 * * * /etc/tz-bot/scripts/renewal.sh 1> /etc/tz-bot/log.txt 2> /etc/tz-bot/err.txt # tz-bot-renewal'
            (crontab -l 2>/dev/null | grep -Fq '# tz-bot-renewal' || crontab -l 2>/dev/null | grep -Fq '/etc/tz-bot/scripts/renewal.sh') || (crontab -l 2>/dev/null; printf '%s\n' "$job") | crontab -
            echo ""
            echo "Renewal options: "
            echo "1. Setup automatic restart of webserver"
            echo "2. Run custom/external script upon renewal"
            echo "3. Only renew certificate"
            read -p "Enter choice [1-3]: " hook_selection
            case $hook_selection in
            1)
                custom_renewhook="no"
                automatic_restart="yes"
                ;;
            2)
                read -p "Please enter the path to the script you want to use: " renewal_hook_script
                custom_renewhook="yes"
                automatic_restart="no"
                ;;
            3)
                echo -e "Proceeding using only automatic renewal of certificates."
                automatic_restart="no"
                custom_renewhook="no"
                ;;
            *)
                ;;
            esac
        else 
            echo -e "\nSelecting manual renewal" && automatic_restart="no"
        fi
    fi
}
function auto_reload() {
    echo -e "\nWhat command would you like to use for reloading your webserver upon installation/renewals?\n1. sudo systemctl reload $server\n2. sudo service $server reload\n3. [NGINX ONLY] sudo /etc/init.d/nginx reload\n4. [APACHE ONLY] sudo /etc/init.d/apache2 reload\n5. Use a custom command"
    read -p "Enter choice [1-5]: " reload_choice
    case $reload_choice in
        1)
            reload_command="sudo systemctl reload $server" && echo ""
            ;;
        2)
            reload_command="sudo service $server reload" && echo ""
            ;;
        3)
            reload_command="sudo /etc/init.d/nginx reload" && echo ""
            ;;
        4)
            reload_command="sudo /etc/init.d/apache2 reload" && echo ""
            ;;
        5)
            echo "" && read -p "Enter reload command: " reload_command && echo ""
            ;;
        *)
            echo -e "Error: Please only enter numbers in the range 1-5.\nRetrying"
            auto_reload
            ;;
    esac
    echo "Attempting to reload server using command: $reload_command"
    if sudo $reload_command; then
        echo "Web server reloaded successfully." && echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
        if grep -q "$reload_command" "/etc/tz-bot/scripts/renewal_hook.sh"; then
            sudo sed -i.bak "\#$reload_command#d" /etc/tz-bot/scripts/renewal_hook.sh
            echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
        fi
    else
        echo "Failed to reload using: '$reload_command'" && echo ""
        if yn_prompt "Would you like to try another reload command?"; then
            auto_reload
        else
            if yn_prompt "Add command to cronjob despite failing?"; then
                echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
                if grep -q "$reload_command" "/etc/tz-bot/scripts/renewal_hook.sh"; then
                    sudo sed -i.bak "\#$reload_command#d" /etc/tz-bot/scripts/renewal_hook.sh
                    echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
                fi
            else
                echo "" && echo "Automatic server reloading cancelled."
            fi
        fi
    fi
}
version_gt() {
    [ "$1" != "$2" ] && \
    [ "$(printf "%s\n%s\n" "$2" "$1" | sort -V | head -n1)" = "$2" ]
}
function upkeep() {
    local_version="1.6.8"
    if [ "$(id -u)" -ne 0 ]; then
        echo 'This script must be run by root' >&2
        exit 1
    fi
    echo "Welcome to TZ-Bot V$local_version"
    SCRIPT_PATH="$(readlink -f "$BASH_SOURCE")"
    remote_version=$(curl -fsSL "https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/main/version.txt"  | tr -d '\r' | tr -d '\n' | xargs)
    if [ -z "$remote_version" ]; then
        echo "Error fetching remote version."
        echo "WARNING: Automatic updates disabled for current session"
    fi
    if version_gt "$remote_version" "$local_version"; then
        if yn_prompt "New version found: $remote_version. Do you want to update?"; then
            curl -fsSL "https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/main/tz-lego-combined.sh" \
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
            sudo curl -L "https://github.com/go-acme/lego/releases/download/v4.31.0/lego_v4.31.0_linux_386.tar.gz" -o /tmp/lego.tar.gz && sudo tar -xvzf /tmp/lego.tar.gz -C /tmp/ && sudo mkdir -p /usr/local/bin && sudo mv /tmp/lego /usr/local/bin/lego && sudo chmod +x /usr/local/bin/lego
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
    if lego -v >/dev/null 2>&1; then
        lego -v
    fi
    cron="true"
    if ! command -v crontab >/dev/null 2>&1; then
        echo "---------WARNING---------" && echo "Crontab is NOT installed." && echo "Automatic renewal via cronjobs will not be available."
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
    if ! [ -e "/etc/tz-bot/scripts/.ca" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.ca
        echo "selected_ca=https://emea.acme.atlas.globalsign.com/directory" > /etc/tz-bot/scripts/.ca
    fi
    if ! [ -e "/etc/tz-bot/scripts/storage" ] ; then
        touch /etc/tz-bot/scripts/storage
    fi
    if ! [ -e "/etc/tz-bot/scripts/.azure_credentials" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.azure_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.aws_credentials" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.aws_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.cloudflare_credentials" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.cloudflare_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.domeneshop_credentials" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.domeneshop_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.infoblox_credentials" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.infoblox_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.godaddy_credentials" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.godaddy_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.scannet_credentials" ] ; then
        install -m 600 /dev/null /etc/tz-bot/scripts/.scannet_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/renewal_list" ] ; then
        touch /etc/tz-bot/scripts/renewal_list
        chmod 600 /etc/tz-bot/scripts/renewal_list
    fi
    if ! [ -e "/etc/tz-bot/scripts/renewal_hook.sh" ] ; then
        touch /etc/tz-bot/scripts/renewal_hook.sh
        chmod +x /etc/tz-bot/scripts/renewal_hook.sh
    fi
    if ! [ -e "/etc/tz-bot/scripts/renewal.sh" ] ; then
        echo "sudo echo '#!/bin/bash' > /etc/tz-bot/scripts/renew_temp.sh" > /etc/tz-bot/scripts/renewal.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.azure_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.aws_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.cloudflare_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.domeneshop_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.infoblox_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.godaddy_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "sudo cat /etc/tz-bot/scripts/renewal_list >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "chmod +x /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "bash /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        echo "rm -rf /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        chmod 600 /etc/tz-bot/scripts/renewal.sh
        chmod +x /etc/tz-bot/scripts/renewal.sh
    fi
    if ! [ -e "/etc/tz-bot/scripts/renewal_force.sh" ] ; then
        echo "sudo echo '#!/bin/bash' > /etc/tz-bot/scripts/renew_temp.sh" > /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.azure_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.aws_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.cloudflare_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.domeneshop_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.infoblox_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.godaddy_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo cat /etc/tz-bot/scripts/renewal_list >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "sudo sed -i 's/--days 30/--days 400/' /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "chmod +x /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "bash /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        echo "rm -rf /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal_force.sh
        chmod 600 /etc/tz-bot/scripts/renewal_force.sh
        chmod +x /etc/tz-bot/scripts/renewal_force.sh
    fi
    if ! [ -e "/etc/tz-bot/scripts/renew_single.sh" ] ; then
        echo "sudo echo '#!/bin/bash' > /etc/tz-bot/scripts/renew_temp.sh" > /etc/tz-bot/scripts/renew_single.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.azure_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.aws_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.cloudflare_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.domeneshop_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.infoblox_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "sudo echo '. /etc/tz-bot/scripts/.godaddy_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "sudo cat /etc/tz-bot/scripts/renew_single_list >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "sudo sed -i 's/--days 30/--days 400/' /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "chmod +x /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "bash /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        echo "rm -rf /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renew_single.sh
        chmod 600 /etc/tz-bot/scripts/renew_single.sh
        chmod +x /etc/tz-bot/scripts/renew_single.sh
    fi
}
function yn_prompt() {
    local prompt="$1"
    local answer

    
    while true; do
        read -n 1 -r -p "$prompt (y/n): " answer
        echo

        case "$answer" in
            y|Y) return 0 ;;  # true
            n|N) return 1 ;;  # false
            *) echo "Please only input "y" or "n"" ;;
        esac
    done
}
function renewal_management() {
    echo -e "\nRenewal management:\n1. List renewals\n2. Run renewal script\n3. Forcefully run renewal script\n4. Forcefully run a specific renewal\n5. Remove a cronjob renewal\n6. Remove all cronjob renewals\n7. Revoke a certificate\n8. Back"
    read -p "Enter choice [1-8]: " renewal_choice
    case $renewal_choice in
        1)
            if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                echo -e "No renewals found."
            else
                echo -e "Current cronjob renewals:"
                awk '{domain=""; wildcard=""; for(i=1;i<=NF;i++){if($i=="--domains"){d=$(i+1); if(d~/^\*\./){wildcard=d} else if(domain==""){domain=d}}} if(wildcard!=""){print NR ": " wildcard} else if(domain!=""){print NR ": " domain}}' /etc/tz-bot/scripts/renewal_list
            fi
            renewal_management
            ;;
        2)
            if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                echo -e "No renewals found."
            else
                echo "Running renewal script at: /etc/tz-bot/scripts/renewal.sh"
                sudo bash /etc/tz-bot/scripts/renewal.sh
            fi
            renewal_management
            ;;
        3)
            if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                echo -e "No renewals found."
            else
                echo "Running forceful renewal script at: /etc/tz-bot/scripts/renewal_force.sh"
                sudo bash /etc/tz-bot/scripts/renewal_force.sh
            fi
            renewal_management
            ;;
        4)
            if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                echo -e "No renewals found."
                renewal_management
            else
                echo -e "Current cronjob renewals:"
                awk '{domain=""; wildcard=""; for(i=1;i<=NF;i++){if($i=="--domains"){d=$(i+1); if(d~/^\*\./){wildcard=d} else if(domain==""){domain=d}}} if(wildcard!=""){print NR ": " wildcard} else if(domain!=""){print NR ": " domain}}' /etc/tz-bot/scripts/renewal_list
            fi
            read -p "Please enter the NUMBER of the renewal you want to run: " renew_single
            if ! [[ "$renew_single" =~ ^[0-9]+$ ]]; then
                echo "Only input whole numbers, e.g., '5'"
                renewal_management
            fi
            sed -n "${renew_single}p" /etc/tz-bot/scripts/renewal_list > /etc/tz-bot/scripts/renew_single_list
            sudo bash /etc/tz-bot/scripts/renew_single.sh
            sudo rm -rf /etc/tz-bot/scripts/renew_single_list
            renewal_management
            ;;
        5)
            if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                echo -e "No renewals found."
                renewal_management
            else
                echo -e "Current cronjob renewals:"
                awk '{domain=""; wildcard=""; for(i=1;i<=NF;i++){if($i=="--domains"){d=$(i+1); if(d~/^\*\./){wildcard=d} else if(domain==""){domain=d}}} if(wildcard!=""){print NR ": " wildcard} else if(domain!=""){print NR ": " domain}}' /etc/tz-bot/scripts/renewal_list
                read -p "Please enter the NUMBER of the renewal you want to remove: " remove_domain
                if ! [[ "$remove_domain" =~ ^[0-9]+$ ]]; then
                    echo "Only input whole numbers, e.g., '5'"
                    renewal_management
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
                renewal_management
                else
                    echo "Removal cancelled."
                    renewal_management
                fi
            fi
            ;;
        6)
            if yn_prompt "Are you sure you want to remove ALL cronjob renewals? This action cannot be undone."; then
                sudo rm /etc/tz-bot/scripts/renewal_hook.sh
                sudo touch /etc/tz-bot/scripts/renewal_hook.sh && sudo chmod +x /etc/tz-bot/scripts/renewal_hook.sh
                sudo rm /etc/tz-bot/scripts/renewal_list
                sudo touch /etc/tz-bot/scripts/renewal_list && chmod 600 /etc/tz-bot/scripts/renewal_list
                sudo crontab -l | grep -v '/etc/tz-bot/scripts/renewal.sh' | sudo crontab -
                echo "All renewals have been removed."
                renewal_management
            else
                echo "Removal cancelled."
                renewal_management
            fi
            ;;
        7)
            read -p "Please input the common name of the certificate you want to revoke: " revoke_domain
            if yn_prompt "Did you order this certificate using a custom path?"; then
                read -p "Please enter the path: " revoke_path
            else
                revoke_path="/etc/tz-bot/certs"
            fi
            . /etc/tz-bot/scripts/.ca
            . /etc/tz-bot/scripts/.user_credentials
            if sudo lego --server "$selected_ca" --email test123@test.com -a --dns manual --path "$revoke_path" --eab --kid "$eab_kid" --hmac "$eab_hmac" --domains "${revoke_domain}" --key-type rsa2048 list; then
                if yn_prompt "Would you like to continue with the revocation?"; then
                sudo lego --server "$selected_ca" --email test123@test.com -a --dns manual --path "${revoke_path}" --eab --kid "$eab_kid" --hmac "$eab_hmac" --domains "${revoke_domain}" --key-type rsa2048 revoke
                renewal_management
                else
                    echo "Revocation cancelled"
                    renewal_management
                fi
            else
                echo "No certificate found, please verify the entered common name and try again"
                renewal_management
            fi
            ;;
        8)
            cert_menu
            ;;
        *)
            echo -e "Error: Please only enter numbers in the range 1-8.\nRetrying"
            renewal_management
            ;;
    esac
}
function read_credentials() {
    if test -f /etc/tz-bot/scripts/.user_credentials; then
        echo
        if yn_prompt "Do you want to reuse saved EAB credentials?"; then
            echo "Please enter the common name(s) for the certificate"
            echo "Multiple sans can be input as a comma separated list"
            echo "Example: *.trustzone.com,trustzone.com"
            read -p "Input: " domain
            return
        fi
    fi
    echo ""
    read -p "Please enter your EAB Key ID: " eab_kid
    read -s -p "Please enter your EAB HMAC Key: " eab_hmac
    echo
    echo "Please enter the common name(s) for the certificate"
    echo "Multiple sans can be input as a comma separated list"
    echo "Example: *.trustzone.com,trustzone.com"
    read -p "Input: " domain
    install -m 600 /dev/null /etc/tz-bot/scripts/.user_credentials
    echo "export eab_kid=\"$eab_kid\"" > /etc/tz-bot/scripts/.user_credentials && echo "export eab_hmac=\"$eab_hmac\"" >> /etc/tz-bot/scripts/.user_credentials
}
function dns_full() {
    echo -e "\nWhich DNS provider would you like to use?\n1. Azure DNS\n2. AWS/Route 53\n3. Cloudflare\n4. Domeneshop\n5. infoblox\n6. GoDaddy\n6. Scannet"
    read -p "Enter choice [1-7]: " renewal_choice
    echo ""
    case $renewal_choice in
        1)
            val_var="--dns azuredns"
            if grep -q "export AZURE" "/etc/tz-bot/scripts/.azure_credentials"; then
                if yn_prompt "Do you want to reuse saved Azure credentials?"; then
                    . /etc/tz-bot/scripts/.azure_credentials
                    return
                fi
            fi
            read -p "Please enter your Azure Client ID: " azure_client_id && echo "export AZURE_CLIENT_ID=\"$azure_client_id\"" > /etc/tz-bot/scripts/.azure_credentials
            read -s -p "Please enter your Azure Client Secret: " azure_client_secret && echo && echo "export AZURE_CLIENT_SECRET=\"$azure_client_secret\"" >> /etc/tz-bot/scripts/.azure_credentials
            read -p "Please enter your Azure Tenant ID: " azure_tenant_id && echo "export AZURE_TENANT_ID=\"$azure_tenant_id\"" >> /etc/tz-bot/scripts/.azure_credentials
            read -p "Please enter your Azure Subscription ID: " azure_subscription_id && echo "export AZURE_SUBSCRIPTION_ID=\"$azure_subscription_id\"" >> /etc/tz-bot/scripts/.azure_credentials
            echo "export AZURE_ENVIRONMENT=\"public\"" >> /etc/tz-bot/scripts/.azure_credentials && chmod 600 /etc/tz-bot/scripts/.azure_credentials && . /etc/tz-bot/scripts/.azure_credentials
            ;;
        2)
            val_var="--dns route53"
            if grep -q "export AWS" "/etc/tz-bot/scripts/.aws_credentials"; then
                if yn_prompt "Do you want to reuse saved AWS credentials?"; then
                    echo ""
                    . /etc/tz-bot/scripts/.aws_credentials
                    return
                fi
            fi
            read -p "Please enter your AWS Access Key ID: " aws_access_key_id && echo "export AWS_ACCESS_KEY_ID=\"$aws_access_key_id\"" > /etc/tz-bot/scripts/.aws_credentials
            read -s -p "Please enter your AWS Secret Access Key: " aws_secret_access_key && echo && echo "export AWS_SECRET_ACCESS_KEY=\"$aws_secret_access_key\"" >> /etc/tz-bot/scripts/.aws_credentials
            read -p "Please enter your AWS Region: " aws_region && echo "export AWS_REGION=\"$aws_region\"" >> /etc/tz-bot/scripts/.aws_credentials
            chmod 600 /etc/tz-bot/scripts/.aws_credentials && . /etc/tz-bot/scripts/.aws_credentials
            ;;
        3)
            val_var="--dns cloudflare"
            if grep -q "export CLOUDFLARE" "/etc/tz-bot/scripts/.cloudflare_credentials"; then
                if yn_prompt "Do you want to reuse saved Cloudflare"; then
                    echo ""
                    . /etc/tz-bot/scripts/.cloudflare_credentials
                    return
                fi
            fi
            read -p "Please enter your Cloudflare account email: " cloudflare_email && echo "export CLOUDFLARE_EMAIL=\"$cloudflare_email\"" > /etc/tz-bot/scripts/.cloudflare_credentials
            read -s -p "Please enter your Cloudflare API Token: " cloudflare_api_token && echo && echo "export CLOUDFLARE_DNS_API_TOKEN=\"$cloudflare_api_token\"" >> /etc/tz-bot/scripts/.cloudflare_credentials
            chmod 600 /etc/tz-bot/scripts/.cloudflare_credentials && . /etc/tz-bot/scripts/.cloudflare_credentials
            ;;
        4)
            val_var="--dns domeneshop"
            if grep -q "export DOMENESHOP" "/etc/tz-bot/scripts/.domeneshop_credentials"; then
                if yn_prompt "Do you want to reuse saved Domeneshop credentials?"; then
                    echo ""
                    . /etc/tz-bot/scripts/.domeneshop_credentials
                    return
                fi
            fi
            read -p "Please enter your Domeneshop API Token: " domeneshop_api_token && echo "export DOMENESHOP_API_TOKEN=\"$domeneshop_api_token\"" > /etc/tz-bot/scripts/.domeneshop_credentials
            read -s -p "Please enter your Domeneshop API Secret: " domeneshop_api_secret && echo && echo "export DOMENESHOP_API_SECRET=\"$domeneshop_api_secret\"" >> /etc/tz-bot/scripts/.domeneshop_credentials
            chmod 600 /etc/tz-bot/scripts/.domeneshop_credentials && . /etc/tz-bot/scripts/.domeneshop_credentials
            ;;
        5)
            val_var="--dns infoblox"
            if grep -q "export INFOBLOX" "/etc/tz-bot/scripts/.infoblox_credentials"; then
                if yn_prompt "Do you want to reuse saved Infoblox credentials?"; then
                    echo ""
                    . /etc/tz-bot/scripts/.infoblox_credentials
                    return
                fi
            fi
            read -p "Please enter your Infoblox username: " infoblox_username && echo "export INFOBLOX_USERNAME=\"$infoblox_username\"" > /etc/tz-bot/scripts/.infoblox_credentials
            read -s -p "Please enter your Infoblox password: " infoblox_password && echo && echo "export INFOBLOX_PASSWORD=\"$infoblox_password\"" >> /etc/tz-bot/scripts/.infoblox_credentials
            read -p "Please enter your Infoblox host: " infoblox_host && echo "export INFOBLOX_HOST=\"$infoblox_host\"" >> /etc/tz-bot/scripts/.infoblox_credentials
            chmod 600 /etc/tz-bot/scripts/.infoblox_credentials && . /etc/tz-bot/scripts/.infoblox_credentials
            ;;
        6)
            val_var="--dns godaddy"
            if grep -q "export GODADDY" "/etc/tz-bot/scripts/.godaddy_credentials"; then
                if yn_prompt "Do you want to reuse saved GoDaddy credentials?"; then
                    echo ""
                    . /etc/tz-bot/scripts/.godaddy_credentials
                    return
                fi
            fi
            read -p "Please enter your GoDaddy API Key: " godaddy_api_key && echo "export GODADDY_API_KEY=\"$godaddy_api_key\"" > /etc/tz-bot/scripts/.godaddy_credentials
            read -s -p "Please enter your GoDaddy API Secret: " godaddy_api_secret && echo && echo "export GODADDY_API_SECRET=\"$godaddy_api_secret\"" >> /etc/tz-bot/scripts/.godaddy_credentials
            chmod 600 /etc/tz-bot/scripts/.godaddy_credentials && . /etc/tz-bot/scripts/.godaddy_credentials
            ;;
        7)
            val_var="--dns scannet"
            if grep -q "export SCANNET" "/etc/tz-bot/scripts/.scannet_credentials"; then
                if yn_prompt "Do you want to reuse saved scannet credentials?"; then
                    echo ""
                    . /etc/tz-bot/scripts/.scannet_credentials
                    return
                fi
            fi
            read -p "Please enter your scannet API Key: " scannet_api_key && echo "export SCANNET_API_KEY=\"$scannet_api_key\"" > /etc/tz-bot/scripts/.scannet_credentials
            chmod 600 /etc/tz-bot/scripts/.scannet_credentials && . /etc/tz-bot/scripts/.scannet_credentials
            ;;
        *)
            echo -e "Error: Please only enter numbers in the range 1-7.\nRetrying"
            dns_full
            ;;
    esac
}
function uninstall() {
    echo -e "Welcome to the TZ-Bot and Lego uninstaller.\nThis will uninstall TZ-Bot and Lego from your system.\nIt will also remove all certificates from /etc/tz-bot/certs/ and all scripts from /etc/tz-bot/scripts/"
    if yn_prompt "Are you sure you want to proceed?"; then
        echo "Uninstalling TZ-Bot and Lego..."
        if sudo rm -rf /etc/tz-bot/; then
            echo "removed /etc/tz-bot/ and all contents inside"
        else
            echo "Error deleting /etc/tz-bot/"
        fi
        if sudo rm -rf /usr/local/bin/tz-bot; then
            echo "removed /usr/local/bin/tz-bot"
        else
            echo "Error deleting /usr/local/bin/tz-bot"
        fi
        if sudo rm -rf /usr/local/bin/lego; then
            echo "Lego have been uninstalled successfully."
        else
            echo "Error deleting /usr/local/bin/lego"
        fi
        sudo crontab -l | grep -v '/etc/tz-bot/scripts/renewal.sh' | sudo crontab -
        if command -v tz-bot >/dev/null 2>&1; then
            echo "Uninstallation of TZ-bot failed. Please remove manually."
        else
            echo "TZ-bot have been uninstalled successfully."
        fi
        exit
    else
        echo "Uninstallation cancelled."
        exit
    fi
}
function cert_menu() {
    echo -e "\nCertificate Menu Options:\n1. Order a new certificate\n2. Renewal Management\n3. Back"
    read -p "Enter choice [1-3]: " cert_menu_choice
    case $cert_menu_choice in
        1)
            new_cert
            echo
            ;;
        2)
            renewal_management
            ;;
        3)
            start_prompt
            ;;
        *)
            echo -e "Error: Please only enter numbers in the range 1-3.\nRetrying"
            cert_menu
            ;;
    esac
}
function settings_menu() {
    echo -e "\nSettings Menu Options:\n1. CA selection\n2. Uninstall TZ-Bot and Lego\n3. Help\n4. Back"
    read -p "Enter choice [1-4]: " settings_menu_choice
    case $settings_menu_choice in
        1)
            ca_selection
            ;;
        2)
            echo -e "You selected to uninstall TZ-Bot and Lego."
            if yn_prompt "Are you sure you want to proceed?"; then
                echo -e "Proceeding to uninstall..."
                uninstall
            else
                echo -e "Uninstallation cancelled."
                settings_menu
            fi
            ;;
        3)
            echo -e "\nFor support, feature requests and other inquiries, please contact TZ support at the following email address:"
            echo "support@trustzone.com"
            settings_menu
            ;;
        4)
            start_prompt
            ;;
        *)
            echo -e "Error: Please only enter numbers in the range 1-4.\nRetrying"
            settings_menu
            ;;
    esac
}
function start_prompt() {
    echo -e "\nMain Menu Options:\n1. Certificates & Renewals\n2. Settings\n3. Exit"
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
            echo -e "Error: Please only enter numbers in the range 1-3.\nRetrying"
            start_prompt
            ;;
    esac
}
function ca_selection() {
    echo -e "\n1. Globalsign\n2. Sectigo DV\n3. Sectigo OV" && read -p "Enter choice [1-3]: " ca_select_choice
    case $ca_select_choice in
        1)
            ca_select="https://emea.acme.atlas.globalsign.com/directory" && ca_print="GlobalSign"
            ;;
        2)
            ca_select="https://acme.sectigo.com/v2/DV" && ca_print="Sectigo DV"
            ;;
        3)
            ca_select="https://acme.sectigo.com/v2/OV" && ca_print="Sectigo OV"
            ;;
        *)
            echo -e "Error: Please only enter numbers in the range 1-3.\nRetrying"
            ca_selection
            ;;
    esac
    if echo "selected_ca=$ca_select" > /etc/tz-bot/scripts/.ca; then
        echo -e "\nSelected $ca_print as your Certificate Authority" && settings_menu
    else
        echo -e "\nError selecting CA..."
        exit 1
    fi
}
function ordering() {
    echo "LEGO command: sudo $lego_var $registration $val_var $path_var $eab $domain_var"
    if sudo $lego_var $registration $val_var $path_var $eab $domain_var; then
        cronjob
    else
        echo -e "\nThere was a problem with the certificate request. Please check your credentials and domain validation." && echo "You can also contact TRUSTZONE support at support@trustzone.com"
        exit
    fi
    if [[ $renewal = yes ]]; then
        echo -e "\nChecking for existing renewal"
        if sudo grep -qF -- "--domains $domain" "/etc/tz-bot/scripts/renewal_list"; then
            echo "Renewal for $domain already exists in renewal list. Skipping addition."
        else
            echo "Updating renewal list at: /etc/tz-bot/scripts/renewal_list" && echo "sudo $lego_var $registration $val_var $path_var --eab $domain_renew_var" >> /etc/tz-bot/scripts/renewal_list
        fi
        if [[ "$automatic_restart" == "yes" ]]; then
            auto_reload
        fi
    fi
    echo -e "\nYour certificate is here: $path"
    cert_menu
}
function new_cert() {
    echo -e "\nWhich web server are you using?\n1: Apache\n2: Nginx\nTip: If you don't see your service/server here, simply select any of the two. It is only used for recommending reload commands later, but you will have the option to use a custom command." && read -p "Enter choice [1-2]: " server_type
    case $server_type in
        1)
            val_var="--apache" && server="apache2" && echo -e "\nApache selected"
            validation
            ;;
        2)
            val_var="--nginx" && server="nginx" && echo -e "\nNginx selected"
            validation
            ;;
        *)
            echo -e "Error: Please only enter numbers in the range 1-2.\nRetrying"
            new_cert
            ;;
    esac
}
function validation() {
    if grep -q "https://emea.acme.atlas.globalsign.com/directory" "/etc/tz-bot/scripts/.ca"; then
        echo -e "\nHow do you want to validate?\n1: Pre-validated domain\n2: DNS validation\n3: HTTP Validation (Requires port 80 to be open)" && read -p "Enter choice [1-3]: " validation_choice
        case $validation_choice in
            1)
                lego_var="-E lego" && val_var="--dns manual" && echo -e "\nMODE: Pre-validated" && read_credentials
                var_definition
                ;;
            2)
                echo -e "\nMODE: DNS" && read_credentials && dns_full
                var_definition
                ;;
            3)
                lego_var="lego" && val_var="--http --http.webroot /var/www/html/" && echo -e "\nMODE: HTTP Validation" && read_credentials
                var_definition
                ;;
            *)
                echo -e "Error: Please only enter numbers in the range 1-3.\nRetrying"
                validation
                ;;
        esac
    else
        echo -e "How do you want to validate?\n1: DNS validation\n2: HTTP Validation (Requires port 80 to be open)" && read -p "Enter choice [1-2]: " validation_choice
        case $validation_choice in
            1)
                lego_var="-E lego" && echo -e "\nMODE: DNS" && read_credentials && dns_full
                var_definition
                ;;
            2)
                lego_var="lego" && val_var="--http --http.webroot /var/www/html/" && echo -e "MODE: \nHTTP Validation" && read_credentials
                var_definition
                ;;
            *)
                echo -e "Error: Please only enter numbers in the range 1-2.\nRetrying"
                validation
                ;;
        esac
    fi
}
function path_selection () {
    read -p "Please enter the full path to save the certificates (e.g., /etc/tz-bot/certs): " custom_path 
    if [ -z "$(echo "$custom_path" | tr -d '[:space:]')" ]; then
        echo "No path specified, try again"
        path_selection
    else
        echo -e "\nCustom path selected: $custom_path"
        if yn_prompt "Continue with selected path?"; then
            echo "path=$custom_path" > /etc/tz-bot/scripts/storage && . /etc/tz-bot/scripts/storage
            path_var="--path $path"
        else
            path_selection
        fi
    fi
}
function var_definition() {
    if [ -f /etc/tz-bot/scripts/.user_credentials ]; then
        . /etc/tz-bot/scripts/.user_credentials
    fi
    . /etc/tz-bot/scripts/.ca
    registration="--server $selected_ca --email test123@test.com -a"
    eab="--eab --kid "${eab_kid:?}" --hmac "${eab_hmac:?}""

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

    domain_var="$domain_args --key-type rsa2048 run"
    if [[ "$custom_renewhook" == "yes" ]]; then
        domain_renew_var="$domain_renew_args --key-type rsa2048 renew --days 30 --renew-hook='sudo bash $renewal_hook_script'"
    else
        domain_renew_var="$domain_renew_args --key-type rsa2048 renew --days 30 --renew-hook='sudo bash /etc/tz-bot/scripts/renewal_hook.sh'"
    fi
    renewal="no"
    echo
    if yn_prompt "Do you want to specify where the certificate is saved?"; then
        path_selection
    else
        echo -e "\nUsing default path for certificate storage: /etc/tz-bot/certs/\n" && echo "path=/etc/tz-bot/certs" > /etc/tz-bot/scripts/storage && . /etc/tz-bot/scripts/storage
        path_var="--path $path"
    fi
    ordering
}

upkeep
start_prompt
