UBUNTU WORKSTATION SETUP SCRIPT
===============================
File:    ubuntu-install.sh
Author:  Muhammad Ali Siddiqui - IT Specialist

This script sets up a newly installed Ubuntu Desktop workstation
(Ubuntu 22.04 / 24.04) automatically, one step after another.


HOW TO RUN
----------
    sudo bash ubuntu-install.sh

Press Enter to start. At the end, type y to reboot.


WHAT THE SCRIPT DOES
--------------------
Before starting:
  - Checks the internet connection. If there is no internet, it waits
    and continues automatically once the laptop is connected.
  - Waits for Ubuntu's automatic updates to finish.

Then it runs these steps:
   1. System update     - updates all packages and cleans up
   2. Root password     - sets the root password
   3. vim               - installs the vim text editor
   4. GDM root login    - allows root to log in on the login screen
   5. OpenSSH server    - installs SSH and allows root login
   6. Printing          - installs CUPS and the printer settings tool
   7. Network printer   - adds G18-Printer (10.65.10.41) as the default printer
   8. Google Chrome     - downloads and installs Google Chrome
   9. Clevis TPM2       - unlocks the encrypted disk automatically at boot
                          (no passphrase needed at startup)
  10. Mattermost        - installs the Mattermost desktop app

If a step fails, the script continues with the next one and shows a
summary at the end. It is safe to run the script again.


LOG FILE
--------
Full details of everything are saved in:
    /var/log/ubuntu-install.log


NOTE
----
The script contains passwords. Keep it private and delete it from the
workstation after the setup is done.
