#!/bin/bash
function cronjob() {
    if cron="true"; then
        read -n 1 -p "Do you want to create a cronjob for automatic renewal? (y/n): " cronjob_choice && echo ""
        if [[ "$cronjob_choice" == "y" ]]; then
            renewal="yes" 
            echo "Selecting automatic renewal"
            job='0 6 * * * /etc/tz-bot/scripts/renewal.sh 2> /dev/null' 
            (crontab -l 2>/dev/null | grep -Fxq -- "$job") || (crontab -l 2>/dev/null; printf '%s\n' "$job") | crontab - 
            echo ""
            read -n 1 -p "Do you want to setup automatic reload of your web server? (This will reload your server AFTER getting a new certificate) (y/n): " reload_choice
            if [[ "$reload_choice" == "y" ]]; then
                automatic_restart="yes"
            else
                automatic_restart="no"
                echo -e "\nProceeding without automatic reload.\nWarning: Your server might not pick up new certificates until it is manually reloaded."
            fi
        else 
            echo -e "\nSelecting manual renewal" && automatic_restart="no"
        fi
    fi
}
function auto_reload() {
    echo -e "\nWhat command would you like to use for reloading your webserver upon installation/renewals?\n1. sudo systemctl reload $server\n2. sudo service reload $server\n3. [NGINX ONLY] sudo /etc/init.d/nginx reload\n4. [APACHE ONLY] sudo /etc/init.d/apache2 reload\n5. Use a custom command"
    read -n 1 -p "Enter choice [1-5]: " reload_choice
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
            echo "Invalid choice, exiting."
            exit 1
            ;;
    esac
    echo "" && echo "Attempting to reload server using command: $reload_command"
    if sudo $reload_command; then
        echo "Web server reloaded successfully." && echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
        if grep -q "$reload_command" "/etc/tz-bot/scripts/renewal_hook.sh"; then
            sudo sed -i.bak "\#$reload_command#d" /etc/tz-bot/scripts/renewal_hook.sh
            echo "$reload_command" >> /etc/tz-bot/scripts/renewal_hook.sh
        fi
    else
        echo "Failed to reload using: '$reload_command'" && echo ""
        read -n 1 -p "Would you like to try another reload command? (y/n): " retry_reload
        if [[ "$retry_reload" = "y" ]]; then
            auto_reload
        else
            echo "" && echo "Automatic server reloading cancelled."
        fi
    fi
}
function upkeep() {
    local_version="1.3.9"
    if [ "$(id -u)" -ne 0 ]; then
        echo 'This script must be run by root' >&2
        exit 1
    fi
    echo "Welcome to TZ-Bot V$local_version"
    SCRIPT_PATH="$(readlink -f "$BASH_SOURCE")"
    version_gt() {
    [ "$1" != "$2" ] && \
    [ "$(printf "%s\n%s\n" "$2" "$1" | sort -V | head -n1)" = "$2" ]
    }
    remote_version=$(curl -fsSL "https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/code-reduction-testing/version.txt"  | tr -d '\r' | tr -d '\n' | xargs)
    if [ -z "$remote_version" ]; then
        echo "Error fetching remote version."
        exit 1
    fi
    if version_gt "$remote_version" "$local_version"; then
        read -n 1 -p "New version found: $remote_version. Do you want to update? (y/n): " update_choice
        if [[ "$update_choice" == "y" ]]; then
            curl -fsSL "https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/code-reduction-testing/tz-lego-combined.sh" \
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
        read -n 1 -p "Do you want TZ-bot to try installing Lego? (y/n): " install_choice
        if [[ "$install_choice" == "y" ]]; then
            echo -e "\nInstalling Lego..."
            sudo curl -L "https://github.com/go-acme/lego/releases/download/v4.27.0/lego_v4.27.0_linux_386.tar.gz" -o /tmp/lego.tar.gz && sudo tar -xvzf /tmp/lego.tar.gz -C /tmp/ && sudo mkdir -p /usr/local/bin && sudo mv /tmp/lego /usr/local/bin/lego && sudo chmod +x /usr/local/bin/lego
            if ! command -v lego >/dev/null 2>&1; then
                echo -e "\nLego installation failed. Please install Lego manually."
                exit 1
                fi
        else
        echo -e "\nLego is required to use TZ-bot. If you need help installing lego, please contact TRUSTZONE support at support@trustzone.com"
            exit 1
        fi
    fi
    cron="true"
    if ! command -v crontab >/dev/null 2>&1; then
        echo "---------WARNING---------" && echo "Crontab is NOT installed." && echo "Automatic renewal via cronjobs will not be available."
        read -n 1 -p "Do you want TZ-bot to try installing cron/crontab? (y/n): " install_cron
        if [[ "$install_cron" == "y" ]]; then
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
        touch /etc/tz-bot/scripts/.ca && sudo echo "selected_ca=https://emea.acme.atlas.globalsign.com/directory" > /etc/tz-bot/scripts/.ca
    fi
    if ! [ -e "/etc/tz-bot/scripts/storage" ] ; then
        touch /etc/tz-bot/scripts/storage
    fi
    if ! [ -e "/etc/tz-bot/scripts/.azure_credentials" ] ; then
        touch /etc/tz-bot/scripts/.azure_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.aws_credentials" ] ; then
        touch /etc/tz-bot/scripts/.aws_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.cloudflare_credentials" ] ; then
        touch /etc/tz-bot/scripts/.cloudflare_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.domeneshop_credentials" ] ; then
        touch /etc/tz-bot/scripts/.domeneshop_credentials
    fi
    if ! [ -e "/etc/tz-bot/scripts/.infoblox_credentials" ] ; then
        touch /etc/tz-bot/scripts/.infoblox_credentials
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
        sudo echo "sudo echo '#!/bin/bash' > /etc/tz-bot/scripts/renew_temp.sh" > /etc/tz-bot/scripts/renewal.sh
        sudo echo "sudo echo '. /etc/tz-bot/scripts/.azure_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo echo "sudo echo '. /etc/tz-bot/scripts/.aws_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo echo "sudo echo '. /etc/tz-bot/scripts/.cloudflare_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo echo "sudo echo '. /etc/tz-bot/scripts/.domeneshop_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo echo "sudo echo '. /etc/tz-bot/scripts/.infoblox_credentials' >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo echo "sudo cat /etc/tz-bot/scripts/renewal_list >> /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo echo "chmod +x /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo chmod +x /etc/tz-bot/scripts/renewal.sh
        sudo echo "bash /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo echo "rm -rf /etc/tz-bot/scripts/renew_temp.sh" >> /etc/tz-bot/scripts/renewal.sh
        sudo chmod +x /etc/tz-bot/scripts/renewal.sh
        chmod 600 /etc/tz-bot/scripts/renewal.sh
        sudo chmod +x /etc/tz-bot/scripts/renewal.sh
    fi
}
function renewal_management() {
    echo -e "\nRenewal management:\n1. List renewals\n2. Force renew all certificates\n3. Remove a cronjob renewal\n4. Remove all cronjob renewals\n5. Back to main menu"
    read -n 1 -p "Enter choice [1-5]: " renewal_choice
    echo
    case $renewal_choice in
        1)
            if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                echo -e "\nNo renewals found."
            else
                echo -e "\nCurrent cronjob renewals:"
                awk '{domain=""; wildcard=""; for(i=1;i<=NF;i++){if($i=="--domains"){d=$(i+1); if(d~/^\*\./){wildcard=d} else if(domain==""){domain=d}}} if(wildcard!=""){print NR ": " wildcard} else if(domain!=""){print NR ": " domain}}' /etc/tz-bot/scripts/renewal_list
            fi
            renewal_management
            ;;
        2)
            echo "Running renewal script at: /etc/tz-bot/scripts/renewal.sh"
            sudo bash /etc/tz-bot/scripts/renewal.sh
            renewal_management
            ;;
        3)
            if ! grep -q "lego" "/etc/tz-bot/scripts/renewal_list"; then
                echo -e "\nNo renewals found."
                renewal_management
            else
                read -p "Please enter the NUMBER of the renewal you want to remove: " remove_domain
                if ! [[ "$remove_domain" =~ ^[0-9]+$ ]]; then
                    echo "Only input whole numbers, e.g., '5'"
                    renewal_management
                fi
                echo "You selected to remove renewal for domain: $remove_domain"
                read -n 1 -p "Are you sure you want to proceed with the removal? (y/n): " confirm_removal
                echo
                if [[ "$confirm_removal" == "y" ]]; then
                    echo "Removing renewal for domain: $remove_domain"
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
        4)
            echo "Are you sure you want to remove ALL cronjob renewals? This action cannot be undone."
            read -n 1 -p "Type 'y' to confirm, or 'n' to cancel: " confirm_all_removal
            echo
            if [[ "$confirm_all_removal" = "y" ]]; then
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
        5)
            start_prompt
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}
function read_credentials() {
    if test -f /etc/tz-bot/scripts/.user_credentials; then
    read -n 1 -p "Do you want to reuse saved EAB credentials? (y/n): " reuse_eab
    echo -e "\n"
        if [[ "$reuse_eab" == "y" ]]; then
            read -p "Please enter your domain: " domain
            echo
            return
        fi
    fi
    read -p "Please enter your EAB Key ID: " eab_kid
    echo 
    read -p "Please enter your EAB HMAC Key: " eab_hmac
    echo 
    read -p "Please enter your domain: " domain
    echo 
    echo "export eab_kid=\"$eab_kid\"" > /etc/tz-bot/scripts/.user_credentials && echo "export eab_hmac=\"$eab_hmac\"" >> /etc/tz-bot/scripts/.user_credentials && chmod 600 /etc/tz-bot/scripts/.user_credentials
}
function dns_full() {
    echo -e "\nWhich DNS provider would you like to use?\n1. Azure DNS\n2. AWS/Route 53\n3. Cloudflare\n4. Domeneshop\n5. infoblox"
    read -n 1 -p "Enter choice [1-5]: " renewal_choice
    echo ""
    case $renewal_choice in
        1)
            val_var="--dns azuredns"
            if grep -q "export AZURE" "/etc/tz-bot/scripts/.azure_credentials"; then
                read -n 1 -p "Do you want to reuse saved Azure credentials? (y/n): " reuse_azure
                echo ""
                if [[ "$reuse_azure" == "y" ]]; then
                    . /etc/tz-bot/scripts/.azure_credentials
                    return
                fi
            fi
            read -p "Please enter your Azure Client ID: " azure_client_id && echo "export AZURE_CLIENT_ID=\"$azure_client_id\"" > /etc/tz-bot/scripts/.azure_credentials
            read -p "Please enter your Azure Client Secret: " azure_client_secret && echo "export AZURE_CLIENT_SECRET=\"$azure_client_secret\"" >> /etc/tz-bot/scripts/.azure_credentials
            read -p "Please enter your Azure Tenant ID: " azure_tenant_id && echo "export AZURE_TENANT_ID=\"$azure_tenant_id\"" >> /etc/tz-bot/scripts/.azure_credentials
            read -p "Please enter your Azure Subscription ID: " azure_subscription_id && echo "export AZURE_SUBSCRIPTION_ID=\"$azure_subscription_id\"" >> /etc/tz-bot/scripts/.azure_credentials
            echo "export AZURE_ENVIRONMENT=\"public\"" >> /etc/tz-bot/scripts/.azure_credentials && chmod 600 /etc/tz-bot/scripts/.azure_credentials && . /etc/tz-bot/scripts/.azure_credentials
            ;;
        2)
            val_var="--dns route53"
            if grep -q "export AWS" "/etc/tz-bot/scripts/.aws_credentials"; then
                read -n 1 -p "Do you want to reuse saved AWS credentials? (y/n): " reuse_aws
                echo ""
                if [[ "$reuse_aws" == "y" ]]; then
                    . /etc/tz-bot/scripts/.aws_credentials
                    return
                fi
            fi
            read -p "Please enter your AWS Access Key ID: " aws_access_key_id && echo "export AWS_ACCESS_KEY_ID=\"$aws_access_key_id\"" > /etc/tz-bot/scripts/.aws_credentials
            read -p "Please enter your AWS Secret Access Key: " aws_secret_access_key && echo "export AWS_SECRET_ACCESS_KEY=\"$aws_secret_access_key\"" >> /etc/tz-bot/scripts/.aws_credentials
            read -p "Please enter your AWS Region: " aws_region && echo "export AWS_REGION=\"$aws_region\"" >> /etc/tz-bot/scripts/.aws_credentials
            chmod 600 /etc/tz-bot/scripts/.aws_credentials && . /etc/tz-bot/scripts/.aws_credentials
            ;;
        3)
            val_var="--dns cloudflare"
            if grep -q "export CLOUDFLARE" "/etc/tz-bot/scripts/.cloudflare_credentials"; then
                read -n 1 -p "Do you want to reuse saved Cloudflare credentials? (y/n): " reuse_cloudflare
                echo ""
                if [[ "$reuse_cloudflare" == "y" ]]; then
                    . /etc/tz-bot/scripts/.cloudflare_credentials
                    return
                fi
            fi
            read -p "Please enter your Cloudflare account email: " cloudflare_email && echo "export CLOUDFLARE_EMAIL=\"$cloudflare_email\"" > /etc/tz-bot/scripts/.cloudflare_credentials
            read -p "Please enter your Cloudflare API Key: " cloudflare_api_key && echo "export CLOUDFLARE_API_KEY=\"$cloudflare_api_key\"" >> /etc/tz-bot/scripts/.cloudflare_credentials
            chmod 600 /etc/tz-bot/scripts/.cloudflare_credentials && . /etc/tz-bot/scripts/.cloudflare_credentials
            ;;
        4)
            val_var="--dns domeneshop"
            if grep -q "export DOMENESHOP" "/etc/tz-bot/scripts/.domeneshop_credentials"; then
                read -n 1 -p "Do you want to reuse saved Domeneshop credentials? (y/n): " reuse_domeneshop
                echo ""
                if [[ "$reuse_domeneshop" == "y" ]]; then
                    . /etc/tz-bot/scripts/.domeneshop_credentials
                    return
                fi
            fi
            read -p "Please enter your Domeneshop API Token: " domeneshop_api_token && echo "export DOMENESHOP_API_TOKEN=\"$domeneshop_api_token\"" > /etc/tz-bot/scripts/.domeneshop_credentials
            read -p "Please enter your Domeneshop API Secret: " domeneshop_api_secret && echo "export DOMENESHOP_API_SECRET=\"$domeneshop_api_secret\"" >> /etc/tz-bot/scripts/.domeneshop_credentials
            chmod 600 /etc/tz-bot/scripts/.domeneshop_credentials && . /etc/tz-bot/scripts/.domeneshop_credentials
            ;;
        5)
            val_var="--dns infoblox"
            if grep -q "export INFOBLOX" "/etc/tz-bot/scripts/.infoblox_credentials"; then
                read -n 1 -p "Do you want to reuse saved Infoblox credentials? (y/n): " reuse_infoblox
                echo ""
                if [[ "$reuse_infoblox" == "y" ]]; then
                    . /etc/tz-bot/scripts/.infoblox_credentials
                    return
                fi
            fi
            read -p "Please enter your Infoblox username: " infoblox_username && echo "export INFOBLOX_USERNAME=\"$infoblox_username\"" > /etc/tz-bot/scripts/.infoblox_credentials
            read -p "Please enter your Infoblox password: " infoblox_password && echo "export INFOBLOX_PASSWORD=\"$infoblox_password\"" >> /etc/tz-bot/scripts/.infoblox_credentials
            read -p "Please enter your Infoblox host: " infoblox_host && echo "export INFOBLOX_HOST=\"$infoblox_host\"" >> /etc/tz-bot/scripts/.infoblox_credentials
            chmod 600 /etc/tz-bot/scripts/.infoblox_credentials && . /etc/tz-bot/scripts/.infoblox_credentials
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}
function uninstall() {
    echo -e "\nWelcome to the TZ-Bot and Lego uninstaller.\nThis will uninstall TZ-Bot and Lego from your system.\nIt will also remove all certificates from /etc/tz-bot/certs/ and all scripts from /etc/tz-bot/scripts/"
    read -n 1 -p "Are you sure you want to proceed? (y/n): " confirm_uninstall
    echo
    if [[ "$confirm_uninstall" == "y" ]]; then
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
            echo "Removed /usr/local/bin/lego"
        else
            echo "Error deleting /usr/local/bin/lego"
        fi
        sudo crontab -l | grep -v '/etc/tz-bot/scripts/renewal.sh' | sudo crontab -
        if command -v lego >/dev/null 2>&1; then
            echo "Uninstallation of Lego failed. Please remove manually."
        else
            echo "Lego have been uninstalled successfully."
        fi
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
function start_prompt() {
    echo -e "\nOptions:\n1. Order a new certificate\n2. Renewal Management\n3. Uninstall TZ-Bot and Lego\n4. CA selection\n5. Exit"
    read -n 1 -p "Enter choice [1-5]: " initial_choice
    echo
    case $initial_choice in
        1)
            echo -e "\nYou selected to order a new certificate."
            new_cert
            echo
            ;;
        2)
            renewal_management
            ;;
        3)
            echo -e "\nYou selected to uninstall TZ-Bot and Lego."
            read -n 1 -p "Are you sure you want to proceed? (y/n): " confirm_uninstall
            if [[ "$confirm_uninstall" == "y" ]]; then
                echo -e "\nProceeding to uninstall..."
                uninstall
            else
                echo -e "\nUninstallation cancelled."
                start_prompt
            fi
            ;;
        4)
            ca_selection
            ;;
        5)
            echo -e "\nExiting."
            exit 0
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
}
function ca_selection() {
    echo -e "\n1. Globalsign\n2. Sectigo DV\n3. Sectigo OV" && read -n 1 -p "Enter choice [1-3]: " ca_select_choice
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
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac
    if echo "selected_ca=$ca_select" > /etc/tz-bot/scripts/.ca; then
        echo -e "\nSelected $ca_print as your Certificate Authority" && start_prompt
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
}
function new_cert() {
    # Prompt for validation method
    echo -e "How do you want to validate?\n1: Pre-validated domain\n2: DNS validation\n3: HTTP Validation (Requires port 80 to be open)" && read -n 1 -p "Enter choice [1-3]: " validation_choice
    echo -e "\n\nWhich web server are you using?\n1: Apache\n2: Nginx" && read -n 1 -p "Enter choice [1-2]: " server_type
    #read -t 0.01 -n 10000 discard    
    case $server_type in
        1)
            val_var="--apache" && server="apache2" && echo -e "\nApache selected"
            ;;
        2)
            val_var="--nginx" && server="nginx" && echo -e "\nNginx selected"
            ;;
        *)
            echo "Invalid choice, exiting."
            exit 1
            ;;
    esac

    case $validation_choice in
        1)
            lego_var="lego" && val_var="--dns manual" && echo -e "MODE: Pre-validated\n" && read_credentials
            ;;
        2)
            lego_var="-E lego" && echo -e "MODE: DNS\n" && read_credentials && dns_full
            ;;
        3)
            lego_var="lego" && val_var="--http --http.webroot /var/www/html/" && echo -e "MODE: HTTP Validation\n" && read_credentials
            ;;
        *)
            echo "Invalid choice. Exiting."
            exit 1
            ;;
    esac

    if [ -f /etc/tz-bot/scripts/.user_credentials ]; then
        . /etc/tz-bot/scripts/.user_credentials
    fi
    . /etc/tz-bot/scripts/.ca
    registration="--server $selected_ca --email test123@test.com -a"
    eab="--eab --kid "${eab_kid:?}" --hmac "${eab_hmac:?}""
    if [[ "$domain" == "*."* ]]; then
        domain_non_wc="${domain#*.}"
        domain_var="--domains "${domain:?}" --domains "${domain_non_wc:?}" --key-type rsa2048 run"
        domain_renew_var="--domains "${domain:?}" --domains "${domain_non_wc:?}" --key-type rsa2048 renew --days 30 --renew-hook='sudo bash /etc/tz-bot/scripts/renewal_hook.sh'"
    else
        domain_var="--domains "${domain:?}" --key-type rsa2048 run"
        domain_renew_var="--domains "${domain:?}" --key-type rsa2048 renew --days 30 --renew-hook='sudo bash /etc/tz-bot/scripts/renewal_hook.sh'"
    fi
    renewal="no"
    read -n 1 -p "Do you want to specify where the certificate is saved? (y/n): " custom_path_choice
    if [[ "$custom_path_choice" == "y" ]]; then
        read -p "Please enter the full path to save the certificates (e.g., /etc/tz-bot/certs): " custom_path 
        echo -e "\nCustom path selected: $custom_path" && echo "path=$custom_path" > /etc/tz-bot/scripts/storage && . /etc/tz-bot/scripts/storage
        path_var="--path $path"
    else
        echo -e "\nUsing default path for certificate storage: /etc/tz-bot/certs/" && echo "path=/etc/tz-bot/certs" > /etc/tz-bot/scripts/storage && . /etc/tz-bot/scripts/storage
        path_var="--path $path"
    fi
    ordering
    start_prompt
}

upkeep
start_prompt