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
# The screen shows a live spinner + progress; the full command output of every
# step is saved to /var/log/ubuntu-install.log
# =============================================================================

# -E : ERR trap also works inside functions/subshells
# -e : stop on errors   -u : error on unset variables
# -o pipefail : a failure anywhere in a pipe counts as a failure
set -Eeuo pipefail

# UTF-8 for the box/emoji characters, and English messages from every tool
# (the script checks some command output, e.g. "enabled" from lpstat).
export LC_ALL=C.UTF-8

# =============================================================================
# SETTINGS
# =============================================================================
AUTHOR='Muhammad Ali Siddiqui'
AUTHOR_TITLE='IT Specialist'

# Root password to set on this workstation (single quotes keep @ etc. as typed).
ROOT_PASSWORD='#######'

# Network printer to add after CUPS is installed.
PRINTER_IP='##########'
PRINTER_NAME='G18-Printer'     # queue name shown in print dialogs (no spaces)

# Existing LUKS disk-encryption passphrase (set during the Ubuntu install).
# Clevis needs it once to add the TPM2 key; the passphrase keeps working too.
LUKS_PASSPHRASE='########'
# Clevis TPM2 policy. '{}' = TPM releases the key on this machine without PCR
# checks. Stricter option: '{"pcr_ids":"7"}' (key only released if the Secure
# Boot state is unchanged).
CLEVIS_TPM2_CONFIG='{}'

LOG_FILE=/var/log/ubuntu-install.log

# =============================================================================
# LOOK & FEEL
# =============================================================================
# Is the output a real terminal? (Decided before output is sent to the log.)
if [[ -t 1 ]]; then IS_TTY=yes; else IS_TTY=no; fi

# Terminal width (used to fit the live "last output line" next to the spinner).
COLS=80
if [[ $IS_TTY == yes ]]; then
    COLS=$(tput cols 2>/dev/null || echo 80)
    if (( COLS > 140 )); then COLS=140; fi
fi

# Basic colors (off when not a terminal).
if [[ $IS_TTY == yes ]]; then
    R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'; ITAL=$'\e[3m'
    RED=$'\e[38;5;203m'; GRN=$'\e[38;5;114m'; YLW=$'\e[38;5;221m'
    BLU=$'\e[38;5;75m';  MAG=$'\e[38;5;170m'; CYN=$'\e[38;5;80m'
else
    R=''; B=''; DIM=''; ITAL=''; RED=''; GRN=''; YLW=''; BLU=''; MAG=''; CYN=''
fi

# Ubuntu-style gradient: orange -> pink -> purple (256-color codes).
GRAD=(214 208 203 198 163 129)

# Print the escape code for one 256-color shade (nothing when not a terminal).
c256() {
    if [[ $IS_TTY == yes ]]; then printf '\e[38;5;%sm' "$1"; fi
}

OK="${GRN}✔${R}"; FAIL="${RED}✖${R}"; WARN="${YLW}▲${R}"; ARROW="${CYN}›${R}"

# PFX = left margin. Inside a step it becomes the colored "┃" frame line.
PFX='  '
info() { echo "${PFX}${ARROW} $*"; }
ok()   { echo "${PFX}${OK} $*"; }
warn() { echo "${PFX}${WARN} ${YLW}$*${R}"; }
fail() { echo "${PFX}${FAIL} ${RED}$*${R}"; }

# Seconds -> "45s" or "2m 05s".
fmt_time() {
    local s=$1
    if (( s >= 60 )); then printf '%dm %02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

# Gradient progress bar: progress_bar <done> <total> <width>
progress_bar() {
    local done=$1 total=$2 width=${3:-30} filled i out=''
    filled=$(( done * width / total ))
    for (( i = 0; i < width; i++ )); do
        if (( i < filled )); then
            out+="$(c256 "${GRAD[i * ${#GRAD[@]} / width]}")█"
        else
            out+="${DIM}░"
        fi
    done
    printf '%s%s' "$out" "$R"
}

SPIN_FRAMES='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

# Spinner shown while waiting for something (e.g. automatic updates to finish).
# Usage: spin_until "<message>" <max-seconds> <command...>   (waits while command succeeds)
# The spinner is drawn on fd 3 (the terminal only), so it never fills the log.
spin_until() {
    local msg=$1 max=$2; shift 2
    local i=0 waited=0
    while "$@" >/dev/null 2>&1; do
        printf '\r\e[K%s%s%s%s %s %s(%ss)%s' "$PFX" "$CYN" "${SPIN_FRAMES:i++%10:1}" "$R" "$msg" "$DIM" "$waited" "$R" >&3
        sleep 1; waited=$((waited + 1))
        if (( waited >= max )); then
            printf '\r\e[K' >&3
            warn "Still busy after ${max}s, continuing anyway"
            return 0
        fi
    done
    printf '\r\e[K' >&3
}

# True only when the internet really works: the name resolves (DNS) AND a
# connection to the Ubuntu archive opens. Catches "Wi-Fi connected but no
# internet". Uses bash's /dev/tcp, so no curl/wget is needed.
internet_ok() {
    timeout 5 getent hosts archive.ubuntu.com >/dev/null 2>&1 &&
    timeout 5 bash -c '</dev/tcp/archive.ubuntu.com/80' >/dev/null 2>&1
}

# Wait (with no time limit, never exits) until the laptop is online.
# Shows a notice once, then a live spinner with a timer on the terminal only.
wait_for_internet() {
    local start i=0 t
    if internet_ok; then
        ok "Internet connection available"
        return 0
    fi
    start=$SECONDS
    echo
    echo "${PFX}${WARN} ${B}${YLW}No internet connection detected${R}"
    echo "${PFX}"
    echo "${PFX}   This setup downloads system updates and software, so an active"
    echo "${PFX}   internet connection is required before it can continue."
    echo "${PFX}"
    echo "${PFX}   Please connect this laptop to the network ${B}(Ethernet cable or Wi-Fi${R}"
    echo "${PFX}   ${B}from the top-right menu)${R}. The setup will resume automatically as"
    echo "${PFX}   soon as a connection is available - there is no need to restart it."
    echo "${PFX}"
    echo "${PFX}   ${DIM}Press Ctrl+C if you want to cancel instead.${R}"
    echo
    printf '\e[?25l' >&3
    until internet_ok; do
        # Animate for ~3 seconds, then check again.
        for (( t = 0; t < 15; t++ )); do
            printf '\r\e[K%s%s%s%s %s %s(%s)%s' "$PFX" "$YLW" "${SPIN_FRAMES:i++%10:1}" "$R" \
                "Waiting for internet connection..." "$DIM" "$(fmt_time $((SECONDS - start)))" "$R" >&3
            sleep 0.2
        done
        printf '\r\e[K%s%s%s%s %s %s(%s)%s' "$PFX" "$CYN" "${SPIN_FRAMES:i++%10:1}" "$R" \
            "Checking connection..." "$DIM" "$(fmt_time $((SECONDS - start)))" "$R" >&3
    done
    printf '\r\e[K\e[?25h' >&3
    ok "${B}${GRN}Internet is connected now - resuming the script${R} ${DIM}(waited $(fmt_time $((SECONDS - start))))${R}"
    sleep 1
}

# Spinner animation used by run_quiet. Runs in the BACKGROUND and draws on
# fd 3 (terminal only) until it is stopped, or until the script that started
# it is gone (e.g. after Ctrl+C), so it can never be left running.
#   spinner_loop <message> <output-file> <start-seconds> <parent-pid>
spinner_loop() {
    local msg=$1 out=$2 start=$3 parent=$4 i=0 last avail
    # Short pause first, so lines printed just before (still on their way
    # through tee) appear on screen before the spinner line, not glued to it.
    sleep 0.15
    while kill -0 "$parent" 2>/dev/null; do
        # Latest non-empty output line, without color codes / \r redraws.
        last=$(tail -c 400 "$out" 2>/dev/null | tr '\r' '\n' \
               | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; /^[[:space:]]*$/d' | tail -n 1) || true
        avail=$(( COLS - ${#msg} - 24 ))
        if (( avail > 8 )); then last=${last:0:avail}; else last=''; fi
        printf '\r\e[K%s%s%s%s %s %s%s%s  %s%s%s' \
            "$PFX" "$CYN" "${SPIN_FRAMES:i++%10:1}" "$R" "$msg" \
            "$DIM" "$(fmt_time $((SECONDS - start)))" "$R" \
            "$DIM$ITAL" "${last:+› $last}" "$R" >&3 2>/dev/null || true
        sleep 0.1
    done
}

# Run a (noisy) command with a live spinner, elapsed time and its latest output
# line, instead of pages of scrolling text.
#   run_quiet "<message>" <command...>
# The full output always goes to the log file. On failure the last 15 lines
# are shown on screen; on success any apt warnings (W:/E:) are shown.
# Returns the command's exit code.
#
# The command itself runs in the FOREGROUND (only the spinner is in the
# background), so Ctrl+C stops it exactly like a normal command - e.g. apt
# finishes the current package cleanly instead of running on invisibly.
run_quiet() {
    local msg=$1; shift
    local out start rc=0 spid took
    out=$(mktemp)
    start=$SECONDS

    if [[ $IS_TTY == yes ]]; then
        printf '\e[?25l' >&3                                   # hide cursor
        spinner_loop "$msg" "$out" "$start" "$BASHPID" &
        spid=$!
        # 3>&- 4>&- : the command doesn't get the script's private terminal/log
        # handles (LVM tools would warn "File descriptor leaked").
        "$@" >"$out" 2>&1 </dev/null 3>&- 4>&- && rc=0 || rc=$?
        kill "$spid" 2>/dev/null || true
        wait "$spid" 2>/dev/null || true
        printf '\r\e[K\e[?25h' >&3                             # show cursor
    else
        info "$msg"
        "$@" >"$out" 2>&1 </dev/null 3>&- 4>&- && rc=0 || rc=$?
    fi

    # Full command output -> log only, through the same single log writer
    # (fd 4) as the screen copy, so log lines stay in order.
    {
        echo "----- ${msg}: $* (exit ${rc})"
        cat "$out"
    } >&4

    took=$(fmt_time $((SECONDS - start)))
    if (( rc == 0 )); then
        ok "${msg} ${DIM}${took}${R}"
        # Warnings from a command that still succeeded (e.g. apt
        # "W: Failed to fetch ...") - show up to 5 so they aren't missed.
        grep -E '^(W|E): ' "$out" 2>/dev/null | head -n 5 \
            | while IFS= read -r line; do warn "$line"; done || true
    else
        fail "${msg} failed (exit ${rc}) - last output:"
        tail -n 15 "$out" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/.*\r//' \
            | awk -v p="$PFX" -v d="$DIM" -v r="$R" '{print p "   " d "│ " $0 r}' || true
    fi
    rm -f "$out"
    return "$rc"
}

# -----------------------------------------------------------------------------
# Must run as root (everything below changes system files)
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "  ${FAIL} Please run as root:  ${B}sudo bash $0${R}"
    exit 1
fi

# fd 3 = the terminal only: spinners/animations are drawn there so they never
# end up in the log file.
if [[ $IS_TTY == yes ]]; then exec 3>/dev/tty; else exec 3>/dev/null; fi

# Always give the cursor back, even after Ctrl+C.
trap 'printf "\e[?25h" >&3 2>/dev/null || true' EXIT

# Copy all output (screen + errors) into the log file as well.
# The log is readable by root only. Colors/redraws are stripped from the log
# copy (the screen still shows them):
#   s/\x1b\[...//   removes color/cursor codes
#   s/.*\r//        keeps only the final text of lines redrawn with \r
#
# fd 4 = the ONE process that writes the log. Both the screen copy (via tee)
# and run_quiet's full command output go through it, so lines stay in order.
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec 4> >(sed -u -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/.*\r//' >> "$LOG_FILE")
exec > >(tee >(cat >&4)) 2>&1
TEE_PID=$!

# Close the output and wait for tee to finish writing, so the last lines are
# shown before the shell prompt comes back. Then reboot (if chosen) or exit.
REBOOT=no
finish() {
    exec >/dev/null 2>&1 4>&-
    wait "$TEE_PID" 2>/dev/null || true
    if [[ $REBOOT == yes ]]; then
        # Output is closed by now, so report a failed reboot on the terminal.
        systemctl reboot || printf '\n   Reboot failed - run:  sudo reboot\n' >&3
    fi
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
    run_quiet "Refreshing package lists" apt-get "${APT_OPTS[@]}" update

    # Upgrade all installed packages to their newest versions.
    run_quiet "Upgrading installed packages" apt-get "${APT_OPTS[@]}" upgrade

    # Remove packages installed as dependencies that are no longer needed.
    run_quiet "Removing unused packages" apt-get "${APT_OPTS[@]}" autoremove

    # Delete cached .deb files that can no longer be downloaded (frees space).
    run_quiet "Cleaning package cache" apt-get "${APT_OPTS[@]}" autoclean
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
    run_quiet "Installing vim" apt-get "${APT_OPTS[@]}" install vim
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
        fail "Root block is still active in $pam_gdm"
        return 1
    fi
    ok "Root block disabled in $pam_gdm"
}

# 5. OpenSSH server with root login --------------------------------------------
step_ssh() {
    # Install the SSH service so you can connect to this workstation remotely
    # (e.g. "ssh root@<workstation-ip>" from your own PC).
    run_quiet "Installing OpenSSH server" apt-get "${APT_OPTS[@]}" install openssh-server

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
    ok "Created /etc/ssh/sshd_config.d/00-permit-root.conf"

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
        run_quiet "Restarting SSH (socket activation)" systemctl restart ssh.socket
        systemctl try-restart ssh.service
    else
        run_quiet "Enabling SSH service" systemctl enable --now ssh.service
        run_quiet "Restarting SSH service" systemctl restart ssh.service
    fi

    # Verify SSH is listening and root login is really in effect.
    systemctl is-active --quiet ssh.socket || systemctl is-active --quiet ssh.service
    local effective
    effective=$(sshd -T | grep -i '^permitrootlogin' || true)
    if [[ ${effective,,} != "permitrootlogin yes" ]]; then
        fail "PermitRootLogin not in effect (sshd reports: '${effective:-nothing}')"
        return 1
    fi
    ok "SSH running, effective setting: ${B}${effective}${R}"
}

# 6. Printing ------------------------------------------------------------------
step_printing() {
    # cups                  = printing system (print server / spooler)
    # system-config-printer = graphical tool to add and manage printers
    run_quiet "Installing CUPS + printer tool" apt-get "${APT_OPTS[@]}" install cups system-config-printer
}

# 7. Network printer -----------------------------------------------------------
step_add_printer() {
    # Make sure the CUPS print service is running now and on every boot.
    run_quiet "Starting print service" systemctl enable --now cups

    # Check the printer answers on the network before trying to add it.
    #   631  = IPP (modern network printing)
    #   9100 = raw/JetDirect (older fallback)
    local has_ipp=no has_raw=no
    timeout 5 bash -c "</dev/tcp/${PRINTER_IP}/631"  2>/dev/null && has_ipp=yes
    timeout 5 bash -c "</dev/tcp/${PRINTER_IP}/9100" 2>/dev/null && has_raw=yes
    if [[ $has_ipp == no && $has_raw == no ]]; then
        fail "Printer ${PRINTER_IP} not reachable on port 631 or 9100"
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
        fail "Queue ${PRINTER_NAME} exists but is not enabled: ${status:-no status}"
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
        fail "Chrome is only available for amd64 (this PC is ${arch})"
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
    # (The live spinner line shows the download progress.)
    if command -v wget >/dev/null 2>&1; then
        run_quiet "Downloading Chrome" wget -q --show-progress --progress=bar:force:noscroll -O "$deb" "$url"
    else
        run_quiet "Downloading Chrome" curl -fL -# -o "$deb" "$url"
    fi

    # apt installs local files as the unprivileged "_apt" user; make the folder
    # and file readable so it doesn't warn about an "unsandboxed" download.
    chmod 755 "$tmp"; chmod 644 "$deb"

    # Install the local .deb - apt pulls in any missing dependencies
    # automatically. The package also adds Google's repo
    # (/etc/apt/sources.list.d/google-chrome.list) so Chrome gets updates
    # with normal system updates.
    run_quiet "Installing Chrome" apt-get "${APT_OPTS[@]}" install "$deb"

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
        fail "No TPM2 device (/dev/tpmrm0). Enable TPM / PTT / fTPM in BIOS."
        return 1
    fi
    ok "TPM2 device found: /dev/tpmrm0"

    # 9.3 Install Clevis and its LUKS, TPM2, initramfs and systemd parts.
    #     clevis-initramfs is what unlocks the root disk early in boot.
    run_quiet "Installing Clevis packages" apt-get "${APT_OPTS[@]}" install \
        clevis clevis-luks clevis-tpm2 clevis-initramfs clevis-systemd

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
    systemctl enable clevis-luks-askpass.path >/dev/null 2>&1 \
        || warn "clevis-luks-askpass.path not available (fine for root disk only)"

    # 9.6 Rebuild the boot image (initramfs) for all kernels so Clevis runs
    #     before the root disk is mounted.
    run_quiet "Rebuilding initramfs for all kernels" update-initramfs -u -k all

    # 9.7 Verify Clevis is inside the boot image of the newest kernel
    #     (/boot/initrd.img always points to the newest one).
    if lsinitramfs /boot/initrd.img | grep clevis >/dev/null; then
        ok "Clevis is included in the initramfs"
    else
        fail "Clevis not found in /boot/initrd.img"
        return 1
    fi

    # Show the final bindings for each partition (pin config only, no secrets).
    for dev in $devices; do
        info "$dev key slots: ${DIM}$(clevis luks list -d "$dev" 2>/dev/null | tr '\n' ' ' || true)${R}"
    done

    if (( failed )); then
        fail "Some encrypted partitions are not set up - see warnings above"
        return 1
    fi
    ok "After reboot the disk unlocks without asking for the passphrase"
}

# 10. Mattermost Desktop (snap) ------------------------------------------------
step_mattermost() {
    # On a fresh install snapd first "seeds" its preinstalled snaps; installing
    # before that finishes fails with "too early for operation". Wait for it.
    # Capped at 15 minutes so a broken snapd can't hang the script forever.
    run_quiet "Waiting for snapd to be ready" timeout 900 snap wait system seed.loaded

    # Install the Mattermost chat client from the Snap Store
    # (already installed = no change, still succeeds).
    run_quiet "Installing Mattermost Desktop" snap install mattermost-desktop
}

# =============================================================================
# STEP LIST:  function | icon | title | description
# =============================================================================
STEPS=(
    "step_update|📦|System update|apt update, upgrade, autoremove, autoclean"
    "step_root_password|🔑|Root password|Set and unlock the root account"
    "step_vim|📝|vim|Terminal text editor"
    "step_gdm_root|👑|GDM root login|Allow root on the graphical login screen"
    "step_ssh|🔐|OpenSSH server|Remote access to this PC, root login allowed"
    "step_printing|🧾|Printing|cups + system-config-printer"
    "step_add_printer|📠|Network printer|Add ${PRINTER_NAME} (${PRINTER_IP}) as default"
    "step_chrome|🌐|Google Chrome|Download and install the official .deb"
    "step_clevis_tpm|🔒|Clevis TPM2|Auto-unlock the encrypted disk at boot"
    "step_mattermost|💬|Mattermost|mattermost-desktop (snap)"
)
TOTAL=${#STEPS[@]}
RESULTS=(); DURATIONS=()

# =============================================================================
# STEP RUNNER - runs steps one at a time and records the result of each
# =============================================================================
run_step() {
    local n=$1 fn=$2 icon=$3 title=$4 desc=$5 start rc took frame
    frame=$(c256 "${GRAD[(n - 1) % ${#GRAD[@]}]}")

    # Step card header:  ┏━━ 📦  STEP 1/10 ━━━━━━
    echo
    echo "  ${frame}┏━━${R} ${icon}  ${B}${frame}STEP ${n}/${TOTAL}${R}  ${frame}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
    echo "  ${frame}┃${R}  ${B}${title}${R}  ${DIM}${desc}${R}"
    echo "  ${frame}┃${R}  $(progress_bar $((n - 1)) "$TOTAL" 30) ${DIM}$(( (n - 1) * 100 / TOTAL ))% overall${R}"
    echo "  ${frame}┃${R}"
    PFX="  ${frame}┃${R}  "
    start=$SECONDS

    # Run the step in a subshell with "stop on first error", so a failing
    # command ends only THIS step. The ERR trap shows which command failed.
    # (It stays quiet for "return 1", run_quiet and the step call itself -
    #  those already printed their own error message.)
    local step_call='"$fn"'
    set +e
    (
        trap '[[ $BASH_COMMAND == "$step_call" || $BASH_COMMAND == return* || $BASH_COMMAND == run_quiet* ]] || fail "Failed at line ${LINENO}: ${BASH_COMMAND}"' ERR
        set -e
        "$fn"
    )
    rc=$?
    set -e

    took=$(fmt_time $((SECONDS - start)))
    DURATIONS+=($((SECONDS - start)))
    if (( rc == 0 )); then
        RESULTS+=(ok)
        echo "  ${frame}┗━━${R} ${OK} ${GRN}${B}${title} done${R} ${DIM}· ${took}${R}"
    else
        RESULTS+=(fail)
        echo "  ${frame}┗━━${R} ${FAIL} ${RED}${B}${title} FAILED${R} ${DIM}· ${took} · continuing with next step${R}"
    fi
    PFX='  '
}

# =============================================================================
# MAIN
# =============================================================================
clear 2>/dev/null || true

# --- Banner (gradient, drawn line by line) ------------------------------------
BANNER=(
    "██╗   ██╗██████╗ ██╗   ██╗███╗   ██╗████████╗██╗   ██╗"
    "██║   ██║██╔══██╗██║   ██║████╗  ██║╚══██╔══╝██║   ██║"
    "██║   ██║██████╔╝██║   ██║██╔██╗ ██║   ██║   ██║   ██║"
    "██║   ██║██╔══██╗██║   ██║██║╚██╗██║   ██║   ██║   ██║"
    "╚██████╔╝██████╔╝╚██████╔╝██║ ╚████║   ██║   ╚██████╔╝"
    " ╚═════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝   ╚═╝    ╚═════╝ "
)
echo
for idx in "${!BANNER[@]}"; do
    echo "   $(c256 "${GRAD[idx]}")${BANNER[idx]}${R}"
    if [[ $IS_TTY == yes ]]; then sleep 0.05; fi
done
echo
echo "   ${B}$(c256 208)W O R K S T A T I O N   S E T U P${R}"
echo
echo "   ${DIM}crafted by${R}  ${B}$(c256 220)${AUTHOR}${R}  ${DIM}·${R}  ${B}$(c256 117)${AUTHOR_TITLE}${R}"
echo "   ${DIM}──────────────────────────────────────────────────────${R}"

# --- System information panel -------------------------------------------------
os_name=$( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null || uname -sr)
model=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ' || true)
cpu=$(lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' || true); cpu=${cpu%%$'\n'*}
ram=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || true)
disk=$(df -h / 2>/dev/null | awk 'NR == 2 {print $2 " total, " $5 " used"}' || true)
ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
if [[ -e /dev/tpmrm0 ]]; then tpm="${GRN}✔ present${R}"; else tpm="${YLW}✖ not found${R}"; fi
if lsblk -rno FSTYPE 2>/dev/null | grep crypto_LUKS >/dev/null; then luks="${GRN}✔ encrypted${R}"; else luks="${DIM}not encrypted${R}"; fi

sysrow() { printf '   %s%-8s%s %s\n' "$CYN" "$1" "$R" "$2"; }
echo
sysrow "Host"   "${B}$(hostname)${R}   ${DIM}${ip:-no IP}${R}"
sysrow "System" "${os_name}"
sysrow "Model"  "${model:-unknown}"
sysrow "CPU"    "${cpu:-unknown}"
sysrow "Memory" "${ram:-?} RAM   ${DIM}·${R}   Disk ${disk:-?}"
sysrow "TPM2"   "${tpm}   ${DIM}·${R}   LUKS ${luks}"
sysrow "Date"   "$(date '+%A, %d %B %Y  %H:%M')"

# --- Installation plan --------------------------------------------------------
echo
echo "   ${B}Installation plan${R}  ${DIM}(${TOTAL} steps, one after another)${R}"
echo
i=1
for s in "${STEPS[@]}"; do
    IFS='|' read -r _ icon title desc <<<"$s"
    printf '   %s%2d%s  %s  %s%-16s%s %s%s%s\n' "$(c256 "${GRAD[(i - 1) % ${#GRAD[@]}]}")" "$i" "$R" "$icon" "$B" "$title" "$R" "$DIM" "$desc" "$R"
    i=$((i + 1))
done
echo
echo "   ${DIM}Full log: ${LOG_FILE}${R}"
echo

# Give the person running it a chance to cancel (skipped if not interactive).
if [[ -r /dev/tty ]] && [[ -t 0 ]]; then
    read -r -p "   ${B}Press ${GRN}Enter${R}${B} to start  ·  ${RED}Ctrl+C${R}${B} to cancel ${R}" _ </dev/tty
fi

# --- Pre-flight checks --------------------------------------------------------
echo
echo "  $(c256 75)◆${R} ${B}Pre-flight checks${R}"

# Internet: every step downloads something, so wait here (without exiting)
# until the laptop is online, then resume automatically.
wait_for_internet

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
    IFS='|' read -r fn icon title desc <<<"$s"
    run_step "$i" "$fn" "$icon" "$title" "$desc"
    i=$((i + 1))
done

# --- Summary table ------------------------------------------------------------
FAILED=0
echo
echo "   $(progress_bar "$TOTAL" "$TOTAL" 46) ${B}100%${R}"
echo
echo "   ${DIM}╭────┬────────────────────┬──────────┬──────────╮${R}"
echo "   ${DIM}│${R} ${B}#${R}  ${DIM}│${R} ${B}Step${R}               ${DIM}│${R}     ${B}Time${R} ${DIM}│${R} ${B}Result${R}   ${DIM}│${R}"
echo "   ${DIM}├────┼────────────────────┼──────────┼──────────┤${R}"
for idx in "${!STEPS[@]}"; do
    IFS='|' read -r _ _ title _ <<<"${STEPS[$idx]}"
    if [[ ${RESULTS[$idx]} == ok ]]; then
        sym=$OK; res="${GRN}OK    ${R}"
    else
        sym=$FAIL; res="${RED}FAILED${R}"; FAILED=$((FAILED + 1))
    fi
    printf '   %s│%s %2d %s│%s %-18s %s│%s %8s %s│%s %s %s %s│%s\n' \
        "$DIM" "$R" $((idx + 1)) "$DIM" "$R" "$title" "$DIM" "$R" \
        "$(fmt_time "${DURATIONS[$idx]}")" "$DIM" "$R" "$sym" "$res" "$DIM" "$R"
done
echo "   ${DIM}╰────┴────────────────────┴──────────┴──────────╯${R}"
echo
echo "   ${DIM}Total time${R} ${B}$(fmt_time $((SECONDS - SCRIPT_START)))${R}   ${DIM}·   Log ${LOG_FILE}${R}"
echo

if (( FAILED == 0 )); then
    # --- Finale ---------------------------------------------------------------
    DONE_ART=(
        "  █████╗ ██╗     ██╗         ██████╗  ██████╗ ███╗   ██╗███████╗"
        " ██╔══██╗██║     ██║         ██╔══██╗██╔═══██╗████╗  ██║██╔════╝"
        " ███████║██║     ██║         ██║  ██║██║   ██║██╔██╗ ██║█████╗  "
        " ██╔══██║██║     ██║         ██║  ██║██║   ██║██║╚██╗██║██╔══╝  "
        " ██║  ██║███████╗███████╗    ██████╔╝╚██████╔╝██║ ╚████║███████╗"
        " ╚═╝  ╚═╝╚══════╝╚══════╝    ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝"
    )
    for idx in "${!DONE_ART[@]}"; do
        echo "  $(c256 "${GRAD[idx]}")${DONE_ART[idx]}${R}"
        if [[ $IS_TTY == yes ]]; then sleep 0.05; fi
    done
    echo
    echo "   ✨ ${B}${GRN}All ${TOTAL} steps completed successfully${R} ✨"
    echo "   ${DIM}crafted by${R}  ${B}$(c256 220)${AUTHOR}${R}  ${DIM}·${R}  ${B}$(c256 117)${AUTHOR_TITLE}${R}"
    echo
    echo "   ${DIM}A reboot applies the login screen and disk auto-unlock changes.${R}"
    if [[ -r /dev/tty ]] && [[ -t 0 ]]; then
        read -r -p "   ${B}Reboot now? ${R}[y/N] " answer </dev/tty || answer=''
        if [[ ${answer,,} == y* ]]; then
            echo "   ${CYN}↻${R} Rebooting..."
            REBOOT=yes
        else
            echo "   ${DIM}OK - reboot later with:${R} ${B}sudo reboot${R}"
        fi
    fi
    finish 0
else
    echo "   ${RED}${B}▲ ${FAILED} step(s) need attention${R}"
    for idx in "${!STEPS[@]}"; do
        IFS='|' read -r _ icon title _ <<<"${STEPS[$idx]}"
        [[ ${RESULTS[$idx]} == ok ]] || echo "     ${FAIL} ${icon}  ${title}"
    done
    echo
    echo "   ${DIM}Check the messages above or ${LOG_FILE}, fix, and run the script again -${R}"
    echo "   ${DIM}steps that already worked are not applied twice.${R}"
    finish 1
fi
