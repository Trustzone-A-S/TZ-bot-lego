# Installation guide:

First, run the following command in your linux terminal to download and install TZ-Bot:

```bash
sudo curl -L https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/main/tz-lego-combined.sh > /tmp/tz-bot && sudo bash /tmp/tz-bot
```

Then you can run "sudo tz-bot" to use the client.

# Uninstallation:
Can be done from TZ-bot main menu.

# Manual uninstall:
Run the following command to uninstall:
```bash
sudo rm -rf /etc/tz-bot/ && sudo rm -rf /usr/local/bin/lego && sudo rm -rf /usr/local/bin/tz-bot
```

This SHOULD uninstall everything TZ-bot created/installed. Certs created on a custom path will remain. Any certs still placed in the default path will be removed.
