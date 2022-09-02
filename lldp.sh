#!/bin/bash
set -e -o pipefail # exit on error
# set -e -o pipefail -x # exit on error, enable command trace

# This script takes no parameter. It has a timeout 60s, regardless of success or failure.
# For each physical nic, it listen to L2 raw socket to receive LLDP multicasts,
# finally out a xml similar to `lldpctl -f xml`, making Talaria Java sides' analyse code
# for lldp.xml be reusable. Example of output:
#
# <?xml version="1.0" encoding="UTF-8"?>
# <lldp label="LLDP neighbors">
#   <interface label="Interface" name="enp130s0f0">
#     <id label="ChassisID" type="mac">08:9e:01:b3:6b:fc</id>
#     <id label="PortID">0/41</id>
#     <name label="SysName">j1-ag16-2</name>
#   </interface>
#   <interface label="Interface" name="enp130s0f1">
#     <id label="ChassisID" type="mac">08:9e:01:b3:6b:fc</id>
#     <id label="PortID">0/35</id>
#     <name label="SysName">j1-ag16-2</name>
#   </interface>
# </lldp>

# This script is assumed to run under sudo and only one instance at a time, I did not do locking.
# I could use advanced bash features to completely make this script not using any file, but
# since this script may be called in some lower version of bash, I did not do not do that.

function cleanup() { rm -fR /tmp/lldp-$$-*; }
trap cleanup INT

find /sys/class/net -mindepth 1 -maxdepth 1 -type l -not -lname '*/virtual/*' -printf '%f\n' > /tmp/lldp-$$-PHYSICAL_NICS
ip -oneline link show up | grep ,LOWER_UP | awk '{print $2}' | tr -d ':' > /tmp/lldp-$$-CONNECTED_NICS
fgrep --line-regexp -f /tmp/lldp-$$-PHYSICAL_NICS /tmp/lldp-$$-CONNECTED_NICS > /tmp/lldp-$$-CONNECTED_PHYSICAL_NICS

while read nic_name; do
  # add a multicast mac address(LLDP destination mac) to the nic, otherwise kernel may not forward LLDP multicast message to it
  ip maddress add 01:80:c2:00:00:0e dev $nic_name
  mac=$(ip -oneline link show $nic_name | grep -Po '(?<= link/ether )([0-9a-f]{2}:){5}[0-9a-f]{2}')

  # run a background job to capture lldp (within 60s), save to $nic_name.xml
  rm -f /tmp/lldp-$$-$nic_name.xml
  sed 's/^    //g' <<'__EOF_OF_PYTHON_SCRIPT' | timeout 60 "$(type -p "${PYTHON:-python3}" || echo python)" - $nic_name $mac > /tmp/lldp-$$-$nic_name.xml &
    import socket, sys, re
    def memview_to_mac(data):
      return ':'.join('{:02x}'.format(x) for x in data.tolist())
    def to_int(char_or_int):
      if type(char_or_int) is int:
        return char_or_int
      return ord(char_or_int)
    def memview_to_str(data):
      return data.tobytes().decode('utf-8', errors='ignore')
    ETH_P_ALL = 3
    my_nic = sys.argv[1]
    my_mac = sys.argv[2]
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    sock.bind((my_nic, 0))
    while True:
      data = memoryview(sock.recv(1514))
      dst_mac = memview_to_mac(data[:6])
      if dst_mac != '01:80:c2:00:00:0e':
        continue
      src_mac = memview_to_mac(data[6:12])
      if src_mac == my_mac:
        continue
      proto = data[12:14]
      if proto != b'\x88\xcc':
        continue
      data = data[14:]
      chassis_mac = ''
      port_id = ''
      sys_name = ''
      while True:
        tlv_type = to_int(data[0]) >> 1
        if tlv_type == 0:
            break
        tlv_len = ((to_int(data[0]) & 1) << 8) + to_int(data[1])
        tlv_data = data[2:2+tlv_len]
        # about the tlv_type, see LLDP_TLV_.* in lldp-tlv.h, about the tlv_data[0], it is a subtype, see LLDP_.*_SUBTYPE_.* in lldp-tlv.h
        if tlv_type == 1 and to_int(tlv_data[0]) == 4:  # LLDP_TLV_CHASSIS_ID=1, LLDP_CHASSISID_SUBTYPE_LLADDR=4
          chassis_mac = memview_to_mac(tlv_data[1:])
        elif tlv_type == 2:  # LLDP_TLV_PORT_ID=2
          #print( "port subtype " + str(to_int(tlv_data[0])))
          if (to_int(tlv_data[0]) == 3): # LLDP_PORTID_SUBTYPE_LLADDR=3
            port_id = memview_to_mac(tlv_data[1:])
          else:
            port_id = memview_to_str(tlv_data[1:])
        elif tlv_type == 5:  # LLDP_TLV_SYSTEM_NAME=5
          sys_name = memview_to_str(tlv_data)
        data = data[2+tlv_len:]
      if chassis_mac and port_id and sys_name and chassis_mac != my_mac:
        print('  <interface label="Interface" name="' + my_nic + '">')
        print('    <id label="ChassisID" type="mac">' + chassis_mac + '</id>')
        print('    <id label="PortID">' + port_id + '</id>')
        print('    <name label="SysName">' + sys_name + '</name>')
        print('  </interface>')
        break
__EOF_OF_PYTHON_SCRIPT

done < /tmp/lldp-$$-CONNECTED_PHYSICAL_NICS

# wait for all background processes done
wait

# print all collected lldp data
echo '<?xml version="1.0" encoding="UTF-8"?>'
echo '<lldp label="LLDP neighbors">'
while read nic_name; do
  if fgrep -q '</interface>' /tmp/lldp-$$-$nic_name.xml; then
    cat /tmp/lldp-$$-$nic_name.xml
  fi
done < /tmp/lldp-$$-CONNECTED_PHYSICAL_NICS
echo '</lldp>'

cleanup
