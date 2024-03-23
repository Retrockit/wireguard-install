#!/bin/bash

WG_CONF="/etc/wireguard/wg0.conf"

install_wireguard() {
  if ! command -v wg > /dev/null || ! command -v wg-quick > /dev/null; then
    echo "Installing Wireguard and required tools..."
    sudo apt update && sudo apt install wireguard wireguard-tools -y
  else
    echo "Wireguard is already installed."
  fi
}

validate_ip() {
  # Assume [Interface] section already exists due to earlier checks or creation
  existing_ip=$(grep '^Address =' "$WG_CONF" | cut -d '=' -f2 | xargs)
  if [[ -n $existing_ip ]]; then
    echo "Existing Wireguard server IP address found: $existing_ip"
    read -p "Do you want to overwrite it? (y/n): " overwrite_decision
    if [[ $overwrite_decision == "y" ]]; then
      read -p "Enter the new Wireguard server IP address (e.g., 10.120.50.50): " new_ip
      if [[ ! $new_ip =~ /24$ ]]; then
        new_ip="${new_ip}/24"
        echo "/24 was automatically appended to the IP address."
      fi
      # Replace the existing IP address
      sudo sed -i "/^Address =/c\Address = $new_ip" "$WG_CONF"
      echo "Wireguard server IP address updated to: $new_ip"
    else
      echo "Keeping the existing IP address."
    fi
  else
    read -p "Enter the Wireguard server IP address (e.g., 10.120.50.50): " new_ip
    if [[ ! $new_ip =~ /24$ ]]; then
      new_ip="${new_ip}/24"
      echo "/24 was automatically appended to your IP address."
    fi
    # Append the new IP address under [Interface]
    sudo sed -i "/^\[Interface\]/a Address = $new_ip" "$WG_CONF"
    echo "Wireguard server IP address set to: $new_ip"
  fi
}

manage_private_key() {
  existing_key=$(grep '^PrivateKey =' "$WG_CONF" | cut -d '=' -f2 | xargs)
  if [[ -n $existing_key ]]; then
    read -p "A private key already exists. Do you want to replace it? (y/n): " replace_decision
    if [[ $replace_decision == "y" ]]; then
      new_key=$(wg genkey)
      # Replace the existing PrivateKey
      sudo sed -i "/^PrivateKey =/c\PrivateKey = $new_key" "$WG_CONF"
      echo "Private key replaced."
    else
      echo "Retaining the existing private key."
    fi
  else
    new_key=$(wg genkey)
    # Append the new PrivateKey under [Interface]
    sudo sed -i "/^\[Interface\]/a PrivateKey = $new_key" "$WG_CONF"
    echo "New private key generated and set."
  fi
}

configure_interface() {
  # Ensure the configuration file exists
  touch "$WG_CONF"

  # Check if the [Interface] section exists
  if ! grep -q "\[Interface\]" "$WG_CONF"; then
    echo "Creating the [Interface] section in $WG_CONF."
    # Create the [Interface] section
    echo -e "[Interface]" | sudo tee "$WG_CONF" > /dev/null
  fi

  # Now that the [Interface] section is guaranteed to exist, validate and set IP, PrivateKey, and ListenPort
  validate_ip
  manage_private_key

  # ListenPort configuration
  # Check if ListenPort already exists, if not add it. This avoids duplicate ListenPort entries.
  if ! grep -q "^ListenPort" "$WG_CONF"; then
    echo "ListenPort = 51820" | sudo tee -a "$WG_CONF" > /dev/null
  fi
}

add_client_peer() {
  read -p "Enter the client's public key: " client_pub_key
  read -p "Enter the client's allowed IPs (e.g., 10.0.0.2): " client_allowed_ips
  if [[ ! $client_allowed_ips =~ /32$ ]]; then
    client_allowed_ips="${client_allowed_ips}/32"
    echo "/32 was automatically appended to the AllowedIPs."
  fi
  sudo bash -c "cat >> $WG_CONF" <<EOF

[Peer]
PublicKey = $client_pub_key
AllowedIPs = $client_allowed_ips
EOF
  echo "Client peer added."
}

add_site_to_site_peer() {
  read -p "Enter the site-to-site peer's public key: " peer_pub_key
  read -p "Enter the peer's allowed IPs (e.g., 192.168.2.0): " peer_allowed_ips
  if [[ ! $peer_allowed_ips =~ /32$ ]]; then
    peer_allowed_ips="${peer_allowed_ips}/32"
    echo "/32 was automatically appended to the AllowedIPs."
  fi
  read -p "Enter the peer's endpoint IP (e.g., 203.0.113.4): " peer_endpoint
  if [[ ! $peer_endpoint =~ :[0-9]+$ ]]; then
    peer_endpoint="${peer_endpoint}:51820"
    echo ":51820 was automatically appended to the Endpoint."
  fi
  sudo bash -c "cat >> $WG_CONF" <<EOF

[Peer]
PublicKey = $peer_pub_key
AllowedIPs = $peer_allowed_ips
Endpoint = $peer_endpoint
EOF
  echo "Site-to-site peer added."
}

add_peers() {
  while true; do
    read -p "Add a client (c) or a site-to-site (s) peer, or finish (f)? " choice
    case $choice in
      c) add_client_peer ;;
      s) add_site_to_site_peer ;;
      f) echo "Finished adding peers." ; break ;;
      *) echo "Invalid option. Please enter 'c' for client, 's' for site-to-site, or 'f' to finish." ;;
    esac
  done
}

# Function to check and open port 51820 on UFW
check_ufw() {
  # Check if UFW is active
  ufw_status=$(sudo ufw status | grep "Status")

  if [[ $ufw_status == *"inactive"* ]]; then
    echo "UFW (Uncomplicated Firewall) is currently inactive."
    read -p "Do you want to enable UFW and set default firewall rules? (y/n): " enable_ufw_decision
    if [[ $enable_ufw_decision == "y" ]]; then
      echo "Enabling UFW and setting default rules..."
      sudo ufw enable
      sudo ufw default deny incoming
      sudo ufw default allow outgoing
      echo "UFW has been enabled and configured with default rules."
    else
      echo "UFW will remain inactive. Proceeding without enabling UFW."
    fi
  else
    echo "UFW is already active."
  fi

  # Check and configure port 51820/UDP for Wireguard if UFW is enabled or was just enabled
  if [[ $enable_ufw_decision == "y" || $ufw_status == *"active"* ]]; then
    if ! sudo ufw status | grep -q "51820/udp"; then
      echo "Opening port 51820/UDP for Wireguard..."
      sudo ufw allow 51820/udp
    else
      echo "Port 51820/UDP is already open."
    fi
  fi
}


main() {
  install_wireguard
  configure_interface
  add_peers
  check_ufw
  echo "Wireguard configuration completed. Review $WG_CONF and adjust as necessary."
  echo "Reload Wireguard with 'wg-quick down wg0 && wg-quick up wg0' to apply changes."
  echo "To start Wireguard on boot, run 'sudo systemctl enable wg-quick@wg0'."
}

main
