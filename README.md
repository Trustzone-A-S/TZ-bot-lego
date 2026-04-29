# Installation guide:

First, run the following command in your linux terminal to download and install TZ-Bot:

```bash
sudo curl -L https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/sudoless/tz-lego-combined.sh > /tmp/tz-bot && sudo bash /tmp/tz-bot
```

To run TZ-Bot:
```bash
sudo tz-bot
``` 

# Usage
TZ-Bot only works with an ACME Pro license from TRUSTZONE.
Using TZ-Bot, you can easily order certificates, and set up automation. TZ-Bot has a built in renewal management menu, as well as Pre-validation, HTTP- and DNS-validation support.

After ordering your certificate, simply change your server's configuration ONCE, to use the certificate. Upon renewal, the certificate will have the same name and path, meaning no further changes are needed. If you also decide to use TZ-Bot's automatic reload, your webserver will be reloaded every time a certificate is renewed, automatically picking up the new certificate.

If you want a specific DNS provider to be added, please reach out to support@trustzone.com.

Relevant knowledge material can be found here: https://trustzone.com/guides/acme-pro-guides/ - Look for guides labeled "ACME Pro" (With either Nginx or Apache @Linux)

# Uninstallation:
Can be done from TZ-bot main menu.

# Manual uninstall:
Run the following command to uninstall:
```bash
sudo rm -rf /etc/tz-bot/ && sudo rm -rf /usr/local/bin/lego && sudo rm -rf /usr/local/bin/tz-bot
```

This SHOULD uninstall everything TZ-bot created/installed. Certs created on a custom path will remain. Any certs still placed in the default path will be removed.

If you set up automation, you will need to remove the cronjob as well by using this command:
```bash
sudo crontab -e
```
