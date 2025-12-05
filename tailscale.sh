#!/bin/bash

function distribution() {
    local DISTRIBUTION=""

    if [ -f "/etc/debian_version" ]; then
        source /etc/os-release
        DISTRIBUTION="${ID}"
    else
        echo "ERROR: Distribution must be ubuntu!"
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
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    
    iptables -t nat -A POSTROUTING -o ${SERVER_PUBLIC_NIC} -j MASQUERADE

    echo "net.ipv4.ip_forward = 1" | tee /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1
    sysctl -p /etc/sysctl.d/99-tailscale.conf

    tee /etc/networkd-dispatcher/routable.d/50-tailscale >/dev/null 2>&1 <<'EOF'
#!/bin/bash

function main() {
    local SERVER_PUBLIC_NIC="$(ip -4 -o route get 1.1.1.1 | awk '{ print $5 }')"

    ethtool -K "${SERVER_PUBLIC_NIC}" rx-udp-gro-forwarding on rx-gro-list off
}

main
EOF
    chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale
    /etc/networkd-dispatcher/routable.d/50-tailscale

    tailscale up --advertise-exit-node=true
    exit 0
}

function remove() {
    if [ -f "/usr/bin/tailscale" ]; then
        iptables -t nat -D POSTROUTING -o ${SERVER_PUBLIC_NIC} -j MASQUERADE

        sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1
        rm /etc/sysctl.d/99-tailscale.conf >/dev/null 2>&1

        ethtool -K $(ip -4 -o route get 1.1.1.1 | awk '{ print $5 }') rx-udp-gro-forwarding off rx-gro-list on
        rm /etc/networkd-dispatcher/routable.d/50-tailscale >/dev/null 2>&1

        apt remove tailscale -y >/dev/null 2>&1
        rm -rf /var/lib/tailscale >/dev/null 2>&1
    else
        echo "NOTICE: Not installed, no need to remove!"
    fi
    exit 0
}

function help() {
    cat <<EOF
USAGE
  bash tailscale.sh [OPTION]

OPTION
  -h, --help    Show help manual
  -i, --install Install Tailscale and configure
  -r, --remove  Remove Tailscale
EOF
    exit 0
}

function main() {
    distribution
    root

    local SERVER_PUBLIC_NIC="$(ip -4 -o route get 1.1.1.1 | awk '{ print $5 }')"

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
