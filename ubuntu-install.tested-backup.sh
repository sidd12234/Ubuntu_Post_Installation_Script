#!/usr/bin/env bash
# =============================================================================
# ubuntu-install.sh
# Post-install setup for an Ubuntu Desktop workstation (22.04 / 24.04, GDM).
# Run it yourself once, right after installing Ubuntu:
#
#     sudo bash ubuntu-install.sh
#
# Steps (run strictly one after another, never in parallel):
#   1. System update      apt update / upgrade / autoremove / autoclean
#   2. Root password      set + unlock the root account
#   3. vim                terminal text editor
#   4. GDM root login     allow root on the graphical login screen
#   5. OpenSSH server     remote access to this workstation, root allowed
#   6. Printing           cups + system-config-printer
#   7. Network printer    add the printer at PRINTER_IP, set as default
#   8. Google Chrome      download the official .deb from Google and install
#   9. Clevis TPM2        unlock the LUKS-encrypted disk automatically at boot
#  10. Mattermost         mattermost-desktop (snap) - last, needs snapd ready
#
# If one step fails, the script reports it, carries on with the next step,
# and shows a summary at the end. Safe to run again: nothing is applied twice.
# Full output is also saved to /var/log/ubuntu-install.log
# =============================================================================

# -E : ERR trap also works inside functions/subshells
# -e : stop on errors   -u : error on unset variables
# -o pipefail : a failure anywhere in a pipe counts as a failure
set -Eeuo pipefail

# Root password to set on this workstation (single quotes keep @ etc. as typed).
ROOT_PASSWORD='Evo@12234'

# Network printer to add after CUPS is installed.
PRINTER_IP='10.65.10.41'
PRINTER_NAME='G18-Printer'     # queue name shown in print dialogs (no spaces)

# Existing LUKS disk-encryption passphrase (set during the Ubuntu install).
# Clevis needs it once to add the TPM2 key; the passphrase keeps working too.
LUKS_PASSPHRASE='Evo@123'
# Clevis TPM2 policy. '{}' = TPM releases the key on this machine without PCR
# checks. Stricter option: '{"pcr_ids":"7"}' (key only released if the Secure
# Boot state is unchanged).
CLEVIS_TPM2_CONFIG='{}'

LOG_FILE=/var/log/ubuntu-install.log

# -----------------------------------------------------------------------------
# Colors and symbols (turned off when output is not a terminal)
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
    RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; MAG=$'\e[35m'; CYN=$'\e[36m'
else
    R=''; B=''; DIM=''; RED=''; GRN=''; YLW=''; BLU=''; MAG=''; CYN=''
fi
OK="${GRN}✔${R}"; FAIL="${RED}✖${R}"; WARN="${YLW}!${R}"; ARROW="${CYN}➜${R}"

info() { echo "  ${ARROW} $*"; }
ok()   { echo "  ${OK} $*"; }
warn() { echo "  ${WARN} ${YLW}$*${R}"; }

# Spinner shown while waiting for something (e.g. automatic updates to finish).
# Usage: spin_until "<message>" <max-seconds> <command...>   (waits until command fails)
spin_until() {
    local msg=$1 max=$2; shift 2
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 waited=0
    while "$@" >/dev/null 2>&1; do
        printf '\r  %s%s%s %s %s(%ss)%s ' "$CYN" "${frames:i++%${#frames}:1}" "$R" "$msg" "$DIM" "$waited" "$R"
        sleep 1; waited=$((waited + 1))
        (( waited >= max )) && { printf '\r\e[K'; warn "Still busy after ${max}s, continuing anyway"; return 0; }
    done
    printf '\r\e[K'
}

# -----------------------------------------------------------------------------
# Must run as root (everything below changes system files)
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "${FAIL} Please run as root:  ${B}sudo bash $0${R}"
    exit 1
fi

# Copy all output (screen + errors) into the log file as well.
# The log is readable by root only. Colors/spinner frames are stripped from
# the log copy (the screen still shows them):
#   s/\x1b\[...//   removes color/cursor codes
#   s/.*\r//        keeps only the final text of lines redrawn with \r
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee >(sed -u -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/.*\r//' >> "$LOG_FILE")) 2>&1
TEE_PID=$!

# Close the output and wait for tee to finish writing, so the last lines are
# shown before the shell prompt comes back. Then exit with the given code.
finish() {
    exec 1>&- 2>&-
    wait "$TEE_PID" 2>/dev/null || true
    exit "$1"
}

# -----------------------------------------------------------------------------
# Settings that keep every command non-interactive and conflict-free
# -----------------------------------------------------------------------------
# No debconf dialogs during installs.
export DEBIAN_FRONTEND=noninteractive
# needrestart (if installed): restart services automatically, never prompt.
export NEEDRESTART_MODE=a

# Options used for every apt-get call:
#   -y -q                       : answer yes, less noisy output
#   DPkg::Lock::Timeout=600     : if another apt/dpkg is running (e.g. automatic
#                                 updates after first boot), WAIT up to 10 min
#                                 for it instead of failing with "Could not get lock"
#   --force-confdef/confold     : when a package update ships a new version of a
#                                 config file we edited, keep OUR version and
#                                 don't stop to ask
APT_OPTS=(-y -q
    -o DPkg::Lock::Timeout=600
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold)

# Copy a file to <file>.bak once, before we first change it.
backup() {
    local f=$1
    if [[ -f "$f" && ! -f "$f.bak" ]]; then
        cp -a "$f" "$f.bak"
        info "Backup saved: ${DIM}$f.bak${R}"
    fi
}

# =============================================================================
# STEP FUNCTIONS - each one does a single job
# =============================================================================

# 1. System update and cleanup -------------------------------------------------
step_update() {
    # Download the latest package lists from the Ubuntu repositories.
    info "Refreshing package lists..."
    apt-get "${APT_OPTS[@]}" update

    # Upgrade all installed packages to their newest versions.
    info "Upgrading installed packages..."
    apt-get "${APT_OPTS[@]}" upgrade

    # Remove packages installed as dependencies that are no longer needed.
    info "Removing unused packages..."
    apt-get "${APT_OPTS[@]}" autoremove

    # Delete cached .deb files that can no longer be downloaded (frees space).
    info "Cleaning package cache..."
    apt-get "${APT_OPTS[@]}" autoclean
}

# 2. Root password -------------------------------------------------------------
step_root_password() {
    # Ubuntu ships with root locked. chpasswd reads "user:password" and sets it
    # without prompting, which also unlocks the account.
    echo "root:${ROOT_PASSWORD}" | chpasswd

    # Verify: passwd -S shows "P" when the account has a usable password.
    [[ $(passwd -S root | awk '{print $2}') == P ]]
    ok "Root account unlocked and password set"
}

# 3. vim -----------------------------------------------------------------------
step_vim() {
    # vim = full version of the 'vi' terminal text editor.
    apt-get "${APT_OPTS[@]}" install vim
}

# 4. Root login on the GDM login screen ----------------------------------------
step_gdm_root() {
    # 4a. /etc/gdm3/custom.conf -> AllowRoot=true in the [security] section.
    #     GDM refuses root logins by default; this turns that off.
    local gdm_conf=/etc/gdm3/custom.conf
    backup "$gdm_conf"
    if grep -qE '^\s*#?\s*AllowRoot\s*=' "$gdm_conf"; then
        # Line already there (maybe commented out): set it to true.
        sed -i -E 's/^\s*#?\s*AllowRoot\s*=.*/AllowRoot=true/' "$gdm_conf"
    elif grep -q '^\[security\]' "$gdm_conf"; then
        # [security] header exists: add the line right under it.
        sed -i '/^\[security\]/a AllowRoot=true' "$gdm_conf"
    else
        # No [security] section: add it at the end.
        printf '\n[security]\nAllowRoot=true\n' >> "$gdm_conf"
    fi
    grep -q '^AllowRoot=true' "$gdm_conf"
    ok "AllowRoot=true set in $gdm_conf"

    # 4b. /etc/pam.d/gdm-password -> comment out the rule that blocks root:
    #     "auth required pam_succeed_if.so user != root quiet_success"
    local pam_gdm=/etc/pam.d/gdm-password
    backup "$pam_gdm"
    sed -i -E 's/^(\s*auth\s+required\s+pam_succeed_if\.so\s+user\s*!=\s*root.*)$/# \1/' "$pam_gdm"

    # Verify: no active (uncommented) root-blocking line may remain.
    if grep -qE '^\s*auth\s+required\s+pam_succeed_if\.so\s+user\s*!=\s*root' "$pam_gdm"; then
        echo "  ${FAIL} Root block is still active in $pam_gdm"
        return 1
    fi
    ok "Root block disabled in $pam_gdm"
}

# 5. OpenSSH server with root login --------------------------------------------
step_ssh() {
    # Install the SSH service so you can connect to this workstation remotely
    # (e.g. "ssh root@<workstation-ip>" from your own PC).
    apt-get "${APT_OPTS[@]}" install openssh-server

    # Allow root login over SSH.
    # NOTE: /etc/ssh/sshd_config(.d) = settings for INCOMING logins to this PC.
    #       /etc/ssh/ssh_config is only for OUTGOING connections from this PC,
    #       and PermitRootLogin there breaks the ssh command.
    #
    # sshd_config starts with "Include /etc/ssh/sshd_config.d/*.conf" and sshd
    # uses the FIRST value it reads, so our own drop-in file named 00-... is
    # read first and wins over anything else.
    install -d -m 0755 /etc/ssh/sshd_config.d
    echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/00-permit-root.conf
    info "Created /etc/ssh/sshd_config.d/00-permit-root.conf"

    # Fallback: also set it in the main file (covers images without the Include).
    local sshd_conf=/etc/ssh/sshd_config
    backup "$sshd_conf"
    if grep -qE '^\s*#?\s*PermitRootLogin\b' "$sshd_conf"; then
        sed -i -E 's/^\s*#?\s*PermitRootLogin\b.*/PermitRootLogin yes/' "$sshd_conf"
    else
        echo 'PermitRootLogin yes' >> "$sshd_conf"
    fi

    # sshd needs this directory to exist for config tests; on 24.04 it may not
    # exist yet because SSH only starts when the first connection arrives.
    install -d -m 0755 /run/sshd

    # Check the config for syntax errors before (re)starting SSH.
    sshd -t
    ok "SSH config syntax OK"

    # Start SSH now and on every boot.
    #   24.04: ssh.socket (socket activation) is enabled by default -> keep that
    #          setup, restart the socket, and restart sshd only if it's running.
    #   22.04: classic ssh.service -> enable and restart it.
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl daemon-reload
        systemctl restart ssh.socket
        systemctl try-restart ssh.service
    else
        systemctl enable --now ssh.service
        systemctl restart ssh.service
    fi

    # Verify SSH is listening and root login is really in effect.
    systemctl is-active --quiet ssh.socket || systemctl is-active --quiet ssh.service
    local effective
    effective=$(sshd -T | grep -i '^permitrootlogin' || true)
    if [[ ${effective,,} != "permitrootlogin yes" ]]; then
        echo "  ${FAIL} PermitRootLogin not in effect (sshd reports: '${effective:-nothing}')"
        return 1
    fi
    ok "SSH running, effective setting: ${B}${effective}${R}"
}

# 6. Printing ------------------------------------------------------------------
step_printing() {
    # cups                  = printing system (print server / spooler)
    # system-config-printer = graphical tool to add and manage printers
    apt-get "${APT_OPTS[@]}" install cups system-config-printer
}

# 7. Network printer -----------------------------------------------------------
step_add_printer() {
    # Make sure the CUPS print service is running now and on every boot.
    systemctl enable --now cups

    # Check the printer answers on the network before trying to add it.
    #   631  = IPP (modern network printing)
    #   9100 = raw/JetDirect (older fallback)
    local has_ipp=no has_raw=no
    timeout 5 bash -c "</dev/tcp/${PRINTER_IP}/631"  2>/dev/null && has_ipp=yes
    timeout 5 bash -c "</dev/tcp/${PRINTER_IP}/9100" 2>/dev/null && has_raw=yes
    if [[ $has_ipp == no && $has_raw == no ]]; then
        echo "  ${FAIL} Printer ${PRINTER_IP} not reachable on port 631 or 9100"
        return 1
    fi
    ok "Printer ${PRINTER_IP} reachable (IPP: ${has_ipp}, raw 9100: ${has_raw})"

    # lpadmin creates (or updates, if it already exists) a print queue:
    #   -p NAME  queue name     -E  enable it and accept jobs
    #   -v URI   printer address
    #   -m       driver: "everywhere" = driverless IPP Everywhere, the printer
    #            itself tells CUPS its capabilities (no vendor driver needed)
    #
    # Printers publish IPP at different paths (HP/Epson/Brother: /ipp/print,
    # many copiers: /ipp or /ipp/lp), so try the common ones in turn.
    local added=no path
    if [[ $has_ipp == yes ]]; then
        for path in ipp/print ipp ipp/lp; do
            info "Trying driverless IPP Everywhere at ipp://${PRINTER_IP}/${path} ..."
            if lpadmin -p "$PRINTER_NAME" -E -v "ipp://${PRINTER_IP}/${path}" -m everywhere 2>/dev/null; then
                added=yes
                ok "Printer answered at /${path}"
                break
            fi
        done
        [[ $added == yes ]] || warn "IPP Everywhere not available, trying fallback"
    fi

    # Fallback: raw socket on port 9100 with the generic PostScript driver
    # (works with most office laser printers / copiers).
    if [[ $added == no && $has_raw == yes ]]; then
        info "Adding printer via socket://${PRINTER_IP}:9100 (Generic PostScript)..."
        lpadmin -p "$PRINTER_NAME" -E -v "socket://${PRINTER_IP}:9100" \
            -m drv:///sample.drv/generic.ppd
        added=yes
    fi
    [[ $added == yes ]]

    # Make it the default printer for all users.
    lpadmin -d "$PRINTER_NAME"

    # Verify the queue exists AND is enabled (lpstat -p alone also succeeds for
    # a disabled queue). grep without -q reads all input, so pipefail is safe.
    local status
    status=$(lpstat -p "$PRINTER_NAME" 2>/dev/null || true)
    if ! grep 'enabled' <<<"$status" >/dev/null; then
        echo "  ${FAIL} Queue ${PRINTER_NAME} exists but is not enabled: ${status:-no status}"
        return 1
    fi

    # cups-browsed can auto-create its own queue for the same printer, so users
    # would see it twice in print dialogs. Just warn - the admin can remove it.
    local queues
    queues=$(lpstat -v 2>/dev/null | grep -c "$PRINTER_IP" || true)
    if (( queues > 1 )); then
        warn "${queues} print queues point to ${PRINTER_IP} (cups-browsed duplicate?) - see: lpstat -v"
    fi
    ok "Printer ${B}${PRINTER_NAME}${R} (${PRINTER_IP}) added, enabled and set as default"
}

# 8. Google Chrome -------------------------------------------------------------
step_chrome() {
    # Already installed? Skip - Chrome keeps itself updated through Google's
    # apt repository, which its package adds during the first install.
    # (dpkg-query status check: a removed-but-not-purged package doesn't count.)
    if [[ $(dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null) == "install ok installed" ]]; then
        ok "Already installed: $(google-chrome --version 2>/dev/null || echo google-chrome-stable)"
        return 0
    fi

    # Google only publishes Chrome for Linux on 64-bit Intel/AMD (amd64).
    local arch
    arch=$(dpkg --print-architecture)
    if [[ $arch != amd64 ]]; then
        echo "  ${FAIL} Chrome is only available for amd64 (this PC is ${arch})"
        return 1
    fi

    # Download the official .deb into a temporary folder.
    local url='https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb'
    local tmp deb
    tmp=$(mktemp -d)
    # Delete the temp folder when this step ends - also if a command fails
    # (each step runs in its own subshell, so EXIT fires at the end of the step).
    trap "rm -rf '$tmp'" EXIT
    deb="$tmp/google-chrome-stable_current_amd64.deb"
    info "Downloading Chrome from dl.google.com..."
    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -O "$deb" "$url"
    else
        curl -fL --progress-bar -o "$deb" "$url"
    fi

    # apt installs local files as the unprivileged "_apt" user; make the folder
    # and file readable so it doesn't warn about an "unsandboxed" download.
    chmod 755 "$tmp"; chmod 644 "$deb"

    # Install the local .deb ("./" path) - apt pulls in any missing
    # dependencies automatically. The package also adds Google's repo
    # (/etc/apt/sources.list.d/google-chrome.list) so Chrome gets updates
    # with normal system updates.
    info "Installing Chrome..."
    apt-get "${APT_OPTS[@]}" install "$deb"

    # Verify the package is installed and show its version.
    [[ $(dpkg-query -W -f='${Status}' google-chrome-stable 2>/dev/null) == "install ok installed" ]]
    ok "Installed: $(google-chrome --version 2>/dev/null || dpkg-query -W -f='google-chrome-stable ${Version}' google-chrome-stable)"
}

# 9. Clevis + TPM2: automatic LUKS unlock at boot ------------------------------
step_clevis_tpm() {
    # NOTE: in pipes below, grep is used WITHOUT -q. "grep -q" stops reading
    # at the first match, the command feeding it gets killed (SIGPIPE), and
    # with "pipefail" the whole check would wrongly count as failed.

    # 9.1 Find all LUKS-encrypted partitions (e.g. /dev/nvme0n1p3).
    #     lsblk -rpno = raw output, full paths, no header, only NAME and FSTYPE.
    local devices
    devices=$(lsblk -rpno NAME,FSTYPE | awk '$2 == "crypto_LUKS" {print $1}')
    if [[ -z $devices ]]; then
        warn "No LUKS-encrypted partition found - nothing to do (disk not encrypted)"
        return 0
    fi
    info "Encrypted partition(s): ${B}$(echo $devices)${R}"

    # 9.2 Check the TPM2 chip is available (/dev/tpmrm0 = TPM2 resource manager).
    #     Done BEFORE installing anything, so PCs without TPM stay untouched.
    if [[ ! -e /dev/tpmrm0 ]]; then
        echo "  ${FAIL} No TPM2 device (/dev/tpmrm0). Enable TPM / PTT / fTPM in BIOS."
        return 1
    fi
    ok "TPM2 device found: /dev/tpmrm0"

    # 9.3 Install Clevis and its LUKS, TPM2, initramfs and systemd parts.
    #     clevis-initramfs is what unlocks the root disk early in boot.
    info "Installing Clevis packages..."
    apt-get "${APT_OPTS[@]}" install clevis clevis-luks clevis-tpm2 clevis-initramfs clevis-systemd

    # 9.4 Bind each encrypted partition to the TPM2 chip.
    #     A partition that can't be handled is skipped with a warning; the
    #     others are still processed and the step is marked failed at the end.
    local dev slot failed=0
    for dev in $devices; do
        # Already bound to tpm2? Don't bind again (avoids duplicate key slots).
        if clevis luks list -d "$dev" 2>/dev/null | grep 'tpm2' >/dev/null; then
            ok "$dev already bound to TPM2"
        else
            # Check the passphrase opens this partition before binding.
            # --test-passphrase only checks it; nothing is unlocked or changed.
            if ! printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open --test-passphrase --key-file=- "$dev"; then
                warn "LUKS passphrase does not open $dev - skipped"
                failed=1; continue
            fi

            # Bind: Clevis adds a new LUKS key slot whose key is sealed by the TPM.
            #   -d  device     -k -  read the existing passphrase from stdin
            #   -y  answer "yes" automatically (no prompts)
            info "Binding $dev to TPM2..."
            if ! printf '%s' "$LUKS_PASSPHRASE" | clevis luks bind -y -k - -d "$dev" tpm2 "$CLEVIS_TPM2_CONFIG"; then
                warn "Binding $dev failed (older TPMs may need CLEVIS_TPM2_CONFIG='{\"key\":\"rsa\"}')"
                failed=1; continue
            fi
            ok "$dev bound to TPM2"
        fi

        # Test that the TPM really gives the key back (what happens at boot).
        # The unlocked key is discarded (>/dev/null) - never shown or logged.
        slot=$(clevis luks list -d "$dev" 2>/dev/null | awk -F: '/tpm2/ && s == "" {s = $1} END {print s}')
        if [[ -n $slot ]] && clevis luks pass -d "$dev" -s "$slot" >/dev/null 2>&1; then
            ok "$dev: TPM unlock test passed (key slot $slot)"
        else
            warn "$dev: TPM could not release the key (slot ${slot:-?}) - disk will still ask for the passphrase"
            failed=1
        fi
    done

    # 9.5 Let Clevis answer password prompts for other encrypted volumes that
    #     are unlocked after boot (the root disk is handled by the initramfs).
    systemctl enable clevis-luks-askpass.path 2>/dev/null \
        || warn "clevis-luks-askpass.path not available (fine for root disk only)"

    # 9.6 Rebuild the boot image (initramfs) for all kernels so Clevis runs
    #     before the root disk is mounted.
    info "Updating initramfs for all kernels (takes a minute)..."
    update-initramfs -u -k all

    # 9.7 Verify Clevis is inside the boot image of the newest kernel
    #     (/boot/initrd.img always points to the newest one).
    if lsinitramfs /boot/initrd.img | grep clevis >/dev/null; then
        ok "Clevis is included in the initramfs"
    else
        echo "  ${FAIL} Clevis not found in /boot/initrd.img"
        return 1
    fi

    # Show the final bindings for each partition (pin config only, no secrets).
    for dev in $devices; do
        info "$dev key slots: $(clevis luks list -d "$dev" 2>/dev/null | tr '\n' ' ' || true)"
    done

    if (( failed )); then
        echo "  ${FAIL} Some encrypted partitions are not set up - see warnings above"
        return 1
    fi
    ok "After reboot the disk unlocks without asking for the passphrase"
}

# 10. Mattermost Desktop (snap) ------------------------------------------------
step_mattermost() {
    # On a fresh install snapd first "seeds" its preinstalled snaps; installing
    # before that finishes fails with "too early for operation". Wait for it.
    # Capped at 15 minutes so a broken snapd can't hang the script forever.
    info "Waiting for snapd to be ready..."
    timeout 900 snap wait system seed.loaded

    # Install the Mattermost chat client from the Snap Store
    # (already installed = no change, still succeeds).
    snap install mattermost-desktop
}

# =============================================================================
# STEP RUNNER - runs steps one at a time and records the result of each
# =============================================================================
STEPS=(
    "step_update|System update|apt update, upgrade, autoremove, autoclean"
    "step_root_password|Root password|Set and unlock the root account"
    "step_vim|vim|Terminal text editor"
    "step_gdm_root|GDM root login|Allow root on the graphical login screen"
    "step_ssh|OpenSSH server|Remote access to this PC, root login allowed"
    "step_printing|Printing|cups + system-config-printer"
    "step_add_printer|Network printer|Add printer ${PRINTER_IP} as ${PRINTER_NAME} (default)"
    "step_chrome|Google Chrome|Download and install the official .deb"
    "step_clevis_tpm|Clevis TPM2|Auto-unlock the encrypted disk at boot"
    "step_mattermost|Mattermost|mattermost-desktop (snap)"
)
TOTAL=${#STEPS[@]}
RESULTS=(); DURATIONS=()

run_step() {
    local n=$1 fn=$2 title=$3 start rc
    echo
    echo "${B}${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo "${B}${BLU} [${n}/${TOTAL}]${R} ${B}${title}${R}"
    echo "${B}${BLU}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    start=$SECONDS

    # Run the step in a subshell with "stop on first error", so a failing
    # command ends only THIS step. The ERR trap shows which command failed.
    # (The trap stays quiet for "return 1" and the step call itself - when a step ends with
    #  its own error message + "return 1", a second line would add nothing.)
    local step_call='"$fn"'
    set +e
    (
        trap '[[ $BASH_COMMAND == "$step_call" || $BASH_COMMAND == return* ]] || echo "  ${FAIL} ${RED}Failed at line ${LINENO}:${R} ${BASH_COMMAND}"' ERR
        set -e
        "$fn"
    )
    rc=$?
    set -e

    DURATIONS+=($((SECONDS - start)))
    if (( rc == 0 )); then
        RESULTS+=(ok);   echo "  ${OK} ${GRN}${title} done${R} ${DIM}($((SECONDS - start))s)${R}"
    else
        RESULTS+=(fail); echo "  ${FAIL} ${RED}${title} FAILED${R} - continuing with next step"
    fi
}

# =============================================================================
# MAIN
# =============================================================================
clear 2>/dev/null || true
cat <<EOF
${B}${MAG}
  ╔══════════════════════════════════════════════════════════╗
  ║          UBUNTU WORKSTATION  ·  POST-INSTALL SETUP        ║
  ╚══════════════════════════════════════════════════════════╝${R}
  ${DIM}Host: $(hostname)   ·   $(. /etc/os-release && echo "$PRETTY_NAME")   ·   $(date '+%Y-%m-%d %H:%M')${R}

  ${B}The following will be installed / configured, in this order:${R}

EOF
i=1
for s in "${STEPS[@]}"; do
    IFS='|' read -r _ title desc <<<"$s"
    printf "   ${CYN}%d${R}  ${B}%-16s${R} ${DIM}%s${R}\n" "$i" "$title" "$desc"
    i=$((i + 1))
done
echo
echo "  ${DIM}Log file: ${LOG_FILE}${R}"
echo

# Give the person running it a chance to cancel (skipped if not interactive).
if [[ -r /dev/tty ]] && [[ -t 0 ]]; then
    read -r -p "  ${B}Press ${GRN}Enter${R}${B} to start, or ${RED}Ctrl+C${R}${B} to cancel...${R} " _ </dev/tty
fi

# --- Pre-flight checks --------------------------------------------------------
echo
echo "${B}${BLU} Pre-flight checks${R}"

# Internet: warn early instead of failing in every step.
if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
    ok "Internet / DNS reachable"
else
    warn "Cannot resolve archive.ubuntu.com - check the network connection"
fi

# Wait for automatic updates that run right after first boot, so our apt
# commands never fight with them over the package lock.
if command -v fuser >/dev/null 2>&1; then
    spin_until "Waiting for automatic updates to finish..." 900 \
        fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock
fi
ok "Package manager is free"

# --- Run all steps, strictly one after another --------------------------------
SCRIPT_START=$SECONDS
i=1
for s in "${STEPS[@]}"; do
    IFS='|' read -r fn title _ <<<"$s"
    run_step "$i" "$fn" "$title"
    i=$((i + 1))
done

# --- Summary ------------------------------------------------------------------
FAILED=0
echo
echo "${B}${MAG}  ╔══════════════════════════════════════════════════════════╗${R}"
echo "${B}${MAG}  ║                         SUMMARY                          ║${R}"
echo "${B}${MAG}  ╚══════════════════════════════════════════════════════════╝${R}"
for idx in "${!STEPS[@]}"; do
    IFS='|' read -r _ title _ <<<"${STEPS[$idx]}"
    if [[ ${RESULTS[$idx]} == ok ]]; then
        printf "   %s  %-18s ${DIM}%4ss${R}\n" "$OK" "$title" "${DURATIONS[$idx]}"
    else
        printf "   %s  ${RED}%-18s${R} ${DIM}%4ss${R}  ${RED}FAILED${R}\n" "$FAIL" "$title" "${DURATIONS[$idx]}"
        FAILED=$((FAILED + 1))
    fi
done
echo
echo "  ${DIM}Total time: $(( (SECONDS - SCRIPT_START) / 60 ))m $(( (SECONDS - SCRIPT_START) % 60 ))s   ·   Log: ${LOG_FILE}${R}"
echo

if (( FAILED == 0 )); then
    echo "  ${OK} ${B}${GRN}All steps completed.${R} Reboot to apply the login screen and disk auto-unlock changes:  ${B}sudo reboot${R}"
    finish 0
else
    echo "  ${FAIL} ${B}${RED}${FAILED} step(s) failed.${R} Check the messages above or ${LOG_FILE}, fix, and run the script again."
    finish 1
fi
