Installation guide:

First, run the following command in your linux terminal:

Depending on the product:

**Sectigo DV:**

sudo curl -L https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/main/tz-lego-secDV.sh > /tmp/tz-bot

**Sectigo OV:**

sudo curl -L https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/main/tz-lego-secOV.sh > /tmp/tz-bot

**Globalsign:**

sudo curl -L https://raw.githubusercontent.com/Trustzone-A-S/TZ-bot-lego/main/tz-lego.sh > /tmp/tz-bot

**Then run this command:**

sudo bash /tmp/tz-bot

**Uninstallation:**
Can be done from TZ-bot main menu.

**Manual uninstall:**
Run the following commands to uninstall:

sudo rm -rf /etc/lego/

sudo rm -rf /usr/local/bin/lego

sudo rm -rf /usr/local/bin/tz-bot

This SHOULD uninstall everything TZ-bot created/installed. Certs created on a custom path will remain. Any certs using default path will be removed.
