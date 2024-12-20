#!/bin/bash

# Variabel Konfigurasi
VLAN_INTERFACE="eth1.10"
VLAN_ID=10
IP_Router="192.168.17.1"          # IP address untuk interface VLAN di Ubuntu
IP_Pref="/24"                     # Subnet mask prefix
IP_Subnet="192.168.17.0"          # Subnet address
IP_BC="255.255.255.0"             # Netmask
IP_Range="192.168.17.2 192.168.17.200"
IP_DNS="8.8.8.8, 8.8.4.4"
DHCP_CONF="/etc/dhcp/dhcpd.conf"  # Tempat Konfigurasi DHCP
NETPLAN_CONF="/etc/netplan/01-netcfg.yaml" # Tempat Konfigurasi Netplan
DDHCP_CONF="/etc/default/isc-dhcp-server" # Tempat konfigurasi default DHCP
SWITCH_IP="192.168.1.2"           # IP Cisco IOL
MIKROTIK_IP="192.168.1.3"         # IP MikroTik
USER_SWITCH="root"                # Username SSH untuk Cisco Switch
USER_MIKROTIK="admin"             # Username SSH default MikroTik
PASSWORD_SWITCH="root"            # Password untuk Cisco Switch
PASSWORD_MIKROTIK=""              # Kosongkan jika MikroTik tidak memiliki password
IPROUTE_ADD="192.168.200.0/24"

set -e  # Menghentikan script jika ada error

echo "Inisialisasi awal ..."

# Menambah Repositori
cat <<EOF | sudo tee /etc/apt/sources.list
deb http://kartolo.sby.datautama.net.id/ubuntu/ focal main restricted universe multiverse
deb http://kartolo.sby.datautama.net.id/ubuntu/ focal-updates main restricted universe multiverse
deb http://kartolo.sby.datautama.net.id/ubuntu/ focal-security main restricted universe multiverse
deb http://kartolo.sby.datautama.net.id/ubuntu/ focal-backports main restricted universe multiverse
deb http://kartolo.sby.datautama.net.id/ubuntu/ focal-proposed main restricted universe multiverse
EOF

sudo apt update
sudo apt install -y sshpass isc-dhcp-server iptables-persistent

# Konfigurasi Pada Netplan
echo "Mengkonfigurasi netplan..."
cat <<EOF | sudo tee $NETPLAN_CONF
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
    eth1:
      dhcp4: no
  vlans:
    $VLAN_INTERFACE:
      id: $VLAN_ID
      link: eth1
      addresses: [$IP_Router$IP_Pref]
EOF

sudo netplan apply

# Konfigurasi DHCP Server
echo "Menyiapkan konfigurasi DHCP server..."
cat <<EOL | sudo tee $DHCP_CONF
subnet $IP_Subnet netmask $IP_BC {
    range $IP_Range;
    option routers $IP_Router;
    option subnet-mask $IP_BC;
    option domain-name-servers $IP_DNS;
    default-lease-time 600;
    max-lease-time 7200;
}
EOL

cat <<EOL | sudo tee $DDHCP_CONF
INTERFACESv4="$VLAN_INTERFACE"
EOL

# Mengaktifkan IP forwarding dan mengonfigurasi IPTables
echo "Mengaktifkan IP forwarding dan mengonfigurasi IPTables..."
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables-save > /etc/iptables/rules.v4

# Restart DHCP server
echo "Restarting DHCP server..."
sudo systemctl restart isc-dhcp-server
sudo systemctl status isc-dhcp-server

# Konfigurasi Cisco IOL
echo "Mengonfigurasi Cisco IOL..."
sshpass -p "$PASSWORD_SWITCH" ssh -o StrictHostKeyChecking=no $USER_SWITCH@$SWITCH_IP <<EOF
enable
configure terminal
vlan $VLAN_ID
name VLAN10
exit
interface Ethernet0/1
switchport mode access
switchport access vlan $VLAN_ID
exit
interface Ethernet0/0
switchport mode trunk
switchport trunk encapsulation dot1q
exit
end
write memory
EOF

# Konfigurasi MikroTik
echo "Mengonfigurasi MikroTik..."
if [ -z "$PASSWORD_MIKROTIK" ]; then
    ssh -o StrictHostKeyChecking=no $USER_MIKROTIK@$MIKROTIK_IP <<EOF
/interface vlan add name=vlan10 vlan-id=$VLAN_ID interface=ether1
/ip address add address=$IP_Router$IP_Pref interface=vlan10
/ip route add dst-address=$IPROUTE_ADD gateway=$IP_Router
EOF
else
    sshpass -p "$PASSWORD_MIKROTIK" ssh -o StrictHostKeyChecking=no $USER_MIKROTIK@$MIKROTIK_IP <<EOF
/interface vlan add name=vlan10 vlan-id=$VLAN_ID interface=ether1
/ip address add address=$IP_Router$IP_Pref interface=vlan10
/ip route add dst-address=$IPROUTE_ADD gateway=$IP_Router
EOF
fi

# Konfigurasi Routing di Ubuntu Server
echo "Menambahkan konfigurasi routing..."
sudo ip route add $IPROUTE_ADD via $MIKROTIK_IP

echo "Otomasi konfigurasi selesai."
