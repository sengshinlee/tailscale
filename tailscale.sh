#!/bin/bash

function distribution() {
    if [ ! -f "/etc/debian_version" ]; then
        echo "ERROR: Linux distribution must be Ubuntu!"
        exit 1
    fi
}

function root() {
    if [ "$(echo ${USER})" != "root" ]; then
        echo "WARNING: You must be root to run the script!"
        exit 1
    fi
}

function install() {
    if [ ! -f "/usr/bin/tailscale" ]; then
        curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
    else
        echo "NOTICE: Installed, no need to reinstall!"
        exit 0
    fi

    echo "net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1
    echo "net.ipv6.conf.all.forwarding = 1" | tee -a /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1
    sysctl -p /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1

    echo "net.core.default_qdisc = fq" | tee /etc/sysctl.d/99-google-bbr.conf >/dev/null 2>&1
    echo "net.ipv4.tcp_congestion_control = bbr" | tee -a /etc/sysctl.d/99-google-bbr.conf >/dev/null 2>&1
    sysctl -p /etc/sysctl.d/99-google-bbr.conf >/dev/null 2>&1

    if [ ! -d "/etc/networkd-dispatcher/routable.d" ]; then
        mkdir -p /etc/networkd-dispatcher/routable.d
    fi
    tee /etc/networkd-dispatcher/routable.d/50-tailscale >/dev/null 2>&1 <<'EOF'
#!/bin/bash

function main() {
    local SERVER_PUBLIC_NIC="$(ip -4 -o route get 1.1.1.1 | awk '{ print $5 }')"

    ethtool -K "${SERVER_PUBLIC_NIC}" rx-udp-gro-forwarding on rx-gro-list off
}

main
EOF

    chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale >/dev/null 2>&1
    /etc/networkd-dispatcher/routable.d/50-tailscale >/dev/null 2>&1

    systemctl enable tailscaled.service >/dev/null 2>&1

    tailscale up --advertise-exit-node=true
    exit 0
}

function install_derper() {
    if [ ! -f "/usr/bin/derper" ]; then
        apt-get install golang -y >/dev/null 2>&1
        go install tailscale.com/cmd/derper@latest >/dev/null 2>&1
        cp go/bin/derper /usr/bin >/dev/null 2>&1
        rm -rf go >/dev/null 2>&1
        echo "NOTICE:"
        echo ""
        echo "  sudo derper --verify-clients=true --hostname=YOUR_DERP_SERVER_DOMAIN &"
        echo ""
    else
        echo "NOTICE: Installed, no need to reinstall!"
    fi
    exit 0
}

function set_peer_relay() {
    tailscale set --relay-server-port=40000 >/dev/null 2>&1
    exit 0
}

function remove() {
    if [ -f "/usr/bin/tailscale" ]; then
        local SERVER_PUBLIC_NIC="$(ip -4 -o route get 1.1.1.1 | awk '{ print $5 }')"

        rm /usr/local/bin/tailscale-cron.sh >/dev/null 2>&1
        rm /var/log/tailscale-cron.log >/dev/null 2>&1

        systemctl stop tailscaled.service >/dev/null 2>&1
        systemctl disable tailscaled.service >/dev/null 2>&1
        rm /usr/lib/systemd/system/tailscaled.service >/dev/null 2>&1
        systemctl daemon-reload >/dev/null 2>&1

        tailscale down >/dev/null 2>&1
        apt-get purge tailscale tailscale-archive-keyring -y >/dev/null 2>&1
        rm -rf ${HOME}/.local/share/tailscale >/dev/null 2>&1
        rm -rf ${HOME}/.config/tailscale >/dev/null 2>&1
        rm /var/cache/apt/archives/tailscale* >/dev/null 2>&1
        rm -rf /var/cache/tailscale >/dev/null 2>&1
        rm /etc/apt/sources.list.d/tailscale.list >/dev/null 2>&1
        apt-get update -y >/dev/null 2>&1

        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1
        sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1
        rm /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1

        sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
        rm /etc/sysctl.d/99-google-bbr.conf >/dev/null 2>&1

        ethtool -K "${SERVER_PUBLIC_NIC}" rx-udp-gro-forwarding off rx-gro-list on >/dev/null 2>&1
        rm /etc/networkd-dispatcher/routable.d/50-tailscale >/dev/null 2>&1

        pkill -15 -f "sudo derper --verify-clients=true --hostname=" >/dev/null 2>&1
        rm /usr/bin/derper >/dev/null 2>&1
        apt-get purge golang -y >/dev/null 2>&1

        echo "NOTICE:"
        echo "  - Remove your cron schedule?"
        echo ""
        echo "      crontab -e"
        echo ""
    else
        echo "NOTICE: Not installed, no need to remove!"
    fi
    exit 0
}

function tailscale_cron() {
    cat >/usr/local/bin/tailscale-cron.sh <<'EOF'
#!/bin/bash

HOSTNAME="$(hostname)"

if ! tailscale status >/dev/null 2>&1; then
    echo "$(date): Tailscale is stopped, starting..." | sudo tee -a /var/log/tailscale-cron.log
    if [ "${HOSTNAME}" == "pikvm" ]; then
        sudo tailscale up --reset
    elif [ "${HOSTNAME}" == "verizon" ] || \
         [ "${HOSTNAME}" == "at&t" ] || \
         [ "${HOSTNAME}" == "t-mobile" ] || \
         [ "${HOSTNAME}" == "cmcc" ] || \
         [ "${HOSTNAME}" == "aws" ] || \
         [ "${HOSTNAME}" == "us-west-1a" ] || \
         [ "${HOSTNAME}" == "us-west-2a" ] || \
         [ "${HOSTNAME}" == "us-west-2-wl1-sfo-wlz-1" ] || \
         [ "${HOSTNAME}" == "ap-east-1a" ] || \
         [ "${HOSTNAME}" == "tc" ]; then
        sudo tailscale up --reset --advertise-exit-node
    else
        sudo tailscale up --reset
    fi
fi

# if [ -f "/usr/bin/derper" ] && [ "${HOSTNAME}" == "derper" ]; then
#     sudo derper --verify-clients=true --hostname=YOUR_DERP_SERVER_DOMAIN &
# fi
EOF
    chmod +x /usr/local/bin/tailscale-cron.sh >/dev/null 2>&1

    echo "NOTICE:"
    echo "  - Add a new cron schedule?"
    echo ""
    echo '      (crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/tailscale-cron.sh") | crontab -'
    echo ""
    echo "  - Edit it again?"
    echo ""
    echo "      crontab -e"
    echo ""
    exit 0
}

function help() {
    cat <<EOF
USAGE
  bash tailscale.sh [OPTION]

OPTION
  -h, --help       Show help manual
  -i, --install    Install Tailscale and configure server
  -d, --derper     Install the latest derper binary
  -p, --peer-relay Set an exit-node as a Tailscale Peer Relay server
  -a, --add        Add a "tailscale up" cron schedule
  -r, --remove     Remove Tailscale
EOF
    exit 0
}

function main() {
    distribution
    root

    if [ "$#" -eq 0 ]; then
        help
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                help
                ;;
            -i|--install)
                install
                ;;
            -d|--derper)
                install_derper
                ;;
            -p|--peer-relay)
                set_peer_relay
                ;;
            -a|--add)
                tailscale_cron
                ;;
            -r|--remove)
                remove
                ;;
            *)
                echo "ERROR: Invalid option \"$1\"!"
                exit 1
                ;;
        esac
        shift
    done
}

main "$@"
