#!/bin/bash
RED="\033[0;31m"
GREEN="\033[0;32m"
ST="\033[0m"

function updateTelegrafConfig {
# expected directory of telegarf configuration as first param (/etc/telegraf)
# backup current config 
sudo cp $1/telegraf.conf $1/$(date +"%F-%H:%M:%S")-telegraf.conf.orig
sudo rm -rf $1/telegraf.conf
echo "# Global Agent Configuration
[agent]
  hostname = \"${moniker}\" # set this to a name you want to identify your node in the grafana dashboard
  flush_interval = \"15s\"
  interval = \"15s\"
# Input Plugins
[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false
[[inputs.disk]]
  ignore_fs = [\"devtmpfs\", \"devfs\"]
[[inputs.io]]
[[inputs.mem]]
[[inputs.net]]
[[inputs.system]]
[[inputs.swap]]
[[inputs.netstat]]
[[inputs.processes]]
[[inputs.kernel]]
[[inputs.diskio]]
# Output Plugin InfluxDB
[[outputs.influxdb]]
  database = \"cashdb\"
  urls = [ \"${mon_serv_url}\" ] # example http://yourownmonitoringnode:8086
  username = \"${mon_serv_username}\" # your database username
  password = \"${mon_serv_passwd}\" # your database user's password
[[inputs.exec]]
  commands = [\"sudo su -c ${mon_evmos_path} -s /bin/bash ${user}\"] # change home and username to the useraccount your validator runs at
  interval = \"15s\"
  timeout = \"5s\"
  data_format = \"influx\"
  data_type = \"integer\""> $HOME/telegraf.conf
sudo mv $HOME/telegraf.conf $1/telegraf.conf
sudo systemctl restart telegraf
}

function installTelegraf {
# install telegraf
if [ -n  "$(ps -A | grep telegraf)" ]
then
echo "Telegaraf installed already"
else 
echo "Begin to install telegraf"
sudo apt update
sudo apt -y install curl jq bc
# install telegraf
sudo cat <<EOF | sudo tee /etc/apt/sources.list.d/influxdata.list
deb https://repos.influxdata.com/ubuntu bionic stable
EOF
sudo curl -sL https://repos.influxdata.com/influxdb.key | sudo apt-key add -
sudo apt update
sudo apt -y install telegraf
sudo systemctl enable --now telegraf
sudo systemctl is-enabled telegraf
# systemctl status telegraf
# make the telegraf user sudo and adm to be able to execute scripts as evmos user
sudo adduser telegraf sudo
sudo adduser telegraf adm
sudo -- bash -c 'echo "telegraf ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers'
fi 
}

function seachRPC {
while read str
do
if [ -n "$(echo $str | grep -oE "^[[[:alnum:]]+]")" ]
then 
    header=$(echo $str | grep -oE "^[[[:alnum:]]+]")
fi
if [ "$header" == "[rpc]" ]
then
    port=$(echo $str | grep -oE 'laddr[[:space:]]*=[[:space:]]*"tcp://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\"' | grep -oP '(?<=:)(\d+)(?=")' )
    if [ -n "$port" ]
    then
        break
    fi
fi
done < "$1"
echo $port
return $(( $port ))
}

function showNode75Logo {
echo -e "$GREEN _   _           _     ______ _____ 
| \ | |         | |   |____  | ____|
|  \| | ___   __| | ___   / /| |__  
| . \` |/ _ \ / _\` |/ _ \ / / |___ \ 
| |\  | (_) | (_| |  __// /   ___) |
|_| \_|\___/ \__,_|\___/_/   |____/ $ST"
}

showNode75Logo
sleep 1s
user=$(whoami)
echo -e "\nThis script will install EVMOS monitoring tools on your server for user $GREEN${user}$ST"
echo -ne "Continue? (y/n):"
until [ -n  "$item" ]
do
read item
case "$item" in
    y|Y) echo "Start installing"
        ;;
    n|N) echo "Exit"
        exit 0
        ;;
    *) echo -ne "Please type answer (y/n):"
        item=""
esac
done

echo -e "Install Telegarf agent:"
# sudo apt update
# sudo apt install curl jq -y
installTelegraf

sleep 1s
path_to_config="$HOME/.cashd/config/config.toml"
echo -e "\nTry to get EVMOS node info from $path_to_config"
COS_PORT_RPC=$( seachRPC $path_to_config )
sleep 1s

until [ -n "$COS_PORT_RPC" ]
do 
    echo -e "Can't parse configuration file $REDpath_to_config$ST"
    echo -e "Type correct path to evmos configuration file (../config/config.toml) or press Ctrl+C for exit:"
    read path_to_config
    COS_PORT_RPC=$( seachRPC $path_to_config )
done
echo -e "Successfully parse EVMOS configuration file."

cd $HOME
COS_BIN_NAME=$(which cashd)

echo -e "Try get data from node"
status=$(curl -s localhost:$COS_PORT_RPC/status)

if [ -z "$status" ]
then
    echo -e "${RED}Can't get response from RPC port: $COS_PORT_RPC $ST"
    echo -e "Exit"
    exit -1
fi

echo "Success!"
moniker=$(jq -r '.result.node_info.moniker' <<<$status)
val_key=$(jq -r '.result.validator_info.pub_key.value' <<<$status)
val_info=$(${COS_BIN_NAME} q staking validators -o json --limit=3000 --node "tcp://localhost:${COS_PORT_RPC}" \
| jq -r  --arg val_key "$val_key" '.validators[] | select(.consensus_pubkey.key==$val_key)')
COS_VALOPER=$(jq -r '.operator_address' <<<$val_info)

echo -e "Node RPC port: $GREEN$COS_PORT_RPC$ST"
echo -e "Node moniker: $GREEN$moniker$ST"
echo -e "Node operator address: $GREEN$COS_VALOPER$ST"

repo="$HOME/mon_evmos"
# echo -e "\nClone monitoring project repo to: ${repo}"
# if ! [ -d $repo ]
# then
#   echo "Clone repository"
#   git clone https://github.com/shurinov/mon_evmos.git
# else
#   echo "Repository exist. Stash local changes and pull"
#   cd $repo
#   git stash
#   git pull
#   cd $HOME
# fi

echo -e "Create $repo/var.sh with node settings"
echo "
#EVMOS monitoring variables for node $moniker
COS_BIN_NAME=${COS_BIN_NAME}
COS_PORT_RPC=${COS_PORT_RPC}
COS_VALOPER=${COS_VALOPER}
"> $repo/mon_var.sh
chmod +x $repo/mon_var.sh
chmod +x $repo/monitor.sh


item=""
until [ -n  "$item" ]
do
echo -ne "Insert Monitoring service URL (example: http://123.45.67.89:8086):"
read mon_serv_url
echo -ne "Do you confirm using ${mon_serv_url} as service URL? (y/n):"
read item
case "$item" in
    y|Y);;
    *) item=""
esac
done

item=""
until [ -n  "$item" ]
do
echo -ne "Insert Monitoring service username (example: metrics):"
read mon_serv_username
echo -ne "Do you confirm using ${mon_serv_username} as service username? (y/n):"
read item
case "$item" in
    y|Y);;
    *) item=""
esac
done

item=""
until [ -n  "$item" ]
do
echo -ne "Insert Monitoring service password (example: password):"
read mon_serv_passwd
echo -ne "Do you confirm using ${mon_serv_passwd} as service password? (y/n):"
read item
case "$item" in
    y|Y);;
    *) item=""
esac
done

mon_evmos_path="${repo}/monitor.sh"
updateTelegrafConfig /etc/telegraf
echo -e "EVMOS monitoring tools was successfully install/upgrade. You could check telegraf logs: \"sudo journalctl -u telegraf -f\""
echo -e "Project github: https://github.com/shurinov/mon_evmos.git"
echo -e "Visit your Grafana dashboard: $(echo ${mon_serv_url} | grep -oP '(?<=)(http://\d+.\d+.\d+.\d+:)(?=\d+)')3000"
