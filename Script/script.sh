#!/bin/bash

PROM_FILE="/etc/node-exporter/monitordb.prom" 

# Remove old metrics file
rm -f "$PROM_FILE"

# Function to write metric to prometheus file
write_metric() {
    local metric=$1
    local value=$2
    echo "$metric $value" >> "$PROM_FILE"
}

###################
#    File Check   #
###################

CHECKSUM_DIR="/etc/node-exporter"

# List of files to be monitored
FILES=(
    "/opt/seamless/conf/redis/redis.conf"
    "/opt/seamless/conf/nginx/nginx.conf"
)

# Function to calculate checksum of a file
get_checksum() {
    local file=$1
    sha256sum "$file" | awk '{print $1}' 
}

# Function to write metric for file changes
write_file_change_metric() {
    local file=$1
    local checksum=$2
    local checksum_file="$CHECKSUM_DIR/$(basename "$file").checksum"
    local service=$(basename "$file")  # Use the file name as the service name, and replace dots with underscores
    
    # Replace dots with underscores in service name
    service="${service//./_}"
    
    if [[ $checksum != $(cat "$checksum_file" 2>/dev/null) ]]; then
        echo "$checksum" > "$checksum_file"
        write_metric "${service}_file_status{service=\"$service\",status=\"Changed\",description=\"File content changed\"}" 1
    else
        write_metric "${service}_file_status{service=\"$service\",status=\"Unchanged\",description=\"No changes detected\"}" 0
    fi
}

# Loop through each file in the list for File Check
for file in "${FILES[@]}"; do
    checksum=$(get_checksum "$file")
    write_file_change_metric "$file" "$checksum"
done

################
# MySQL checks #
################

# Function to get MySQL variable value
get_mysql_value() {
    local query=$1
    mysql -urefill -prefill -e "$query" 2>/dev/null | grep "Value: \d*" | cut -d ":" -f2 | cut -d " " -f2
}

# Function to get MySQL Galera status
get_galera_status() {
    local query=$1
    mysql -urefill -prefill -e "$query" 2>/dev/null | grep -E "Primary|Non-Primary|Disconnected|Unknown" | awk '{print $2}'
}

# Fetching MySQL variables
mysqlconnection=$(get_mysql_value "SHOW STATUS WHERE variable_name='Threads_connected' \G")
mysql=$(ps -ef | grep -c '[m]ysql')
mysqlclustercount=$(get_mysql_value "SHOW STATUS LIKE 'wsrep_cluster_size' \G")
mysqllongquery=$(grep 'Query_time:' /var/lib/mysql/seamless-sfostg01-slow.log | tail -n 1 | cut -d ":" -f2 | cut -d " " -f2)
mysqlreplication=$(mysql -urefill -prefill -e "SHOW SLAVE STATUS \G" 2>/dev/null | grep "Seconds_Behind_Master:" | cut -d ":" -f2 | tr -d " ")
wsrep_cluster_status=$(get_galera_status "SHOW STATUS LIKE 'wsrep_cluster_status' \G")
wsrep_ready=$(get_mysql_value "SHOW STATUS LIKE 'wsrep_ready' \G")
wsrep_connected=$(get_mysql_value "SHOW STATUS LIKE 'wsrep_connected' \G")

# MySQL connection status
if [[ $mysqlconnection -ge 2000 ]]; then
    write_metric "mysql_db_connection{service=\"mysql\",status=\"Critical\"}" "$mysqlconnection"
elif [[ $mysqlconnection -ge 1000 ]]; then
    write_metric "mysql_db_connection{service=\"mysql\",status=\"Warning\"}" "$mysqlconnection"
else
    write_metric "mysql_db_connection{service=\"mysql\",status=\"OK\"}" "$mysqlconnection"
fi

# MySQL status
if [[ $mysql -gt 0 ]]; then
    write_metric "mysql_db_status{service=\"mysql\",status=\"Up\"}" 1
else
    write_metric "mysql_db_status{service=\"mysql\",status=\"Down\"}" 0
fi

# MySQL Galera Cluster Size
if [[ -z $mysqlclustercount ]]; then
    write_metric "mysql_galera_cluster_count{service=\"mysql\",status=\"Unknown\"}" -1
elif [[ $mysqlclustercount -ge 3 ]]; then
    write_metric "mysql_galera_cluster_count{service=\"mysql\",status=\"Healthy\"}" "$mysqlclustercount"
else
    write_metric "mysql_galera_cluster_count{service=\"mysql\",status=\"Degraded\"}" "$mysqlclustercount"
fi

# MySQL long query
t1=100
t2=500
if (( $(echo "$mysqllongquery > $t1" | awk '{print ($1 > $2)}') && $(echo "$mysqllongquery < $t2" | awk '{print ($1 < $2)}') )); then
    write_metric "mysql_db_longquery{service=\"mysql db long query\",status=\"Warning\"}" "$mysqllongquery"
elif (( $(echo "$mysqllongquery > $t2" | awk '{print ($1 > $2)}') )); then
    write_metric "mysql_db_longquery{service=\"mysql db long query\",status=\"Critical\"}" "$mysqllongquery"
else
    write_metric "mysql_db_longquery{service=\"mysql db long query\",status=\"Normal\"}" "$mysqllongquery"
fi

# MySQL replication status
if [[ -z "$mysqlreplication" ]]; then
    write_metric "mysqlreplication{service=\"mysql\",status=\"No Replication\"}" 0
elif [[ $mysqlreplication -eq 0 ]]; then
    write_metric "mysqlreplication{service=\"mysql\",status=\"OK\"}" "$mysqlreplication"
else
    write_metric "mysqlreplication{service=\"mysql\",status=\"Lagging\"}" "$mysqlreplication"
fi

# Galera Cluster Status
case $wsrep_cluster_status in
    Primary)
        write_metric "mysql_galera_cluster_status{status=\"Primary\"}" 1
        ;;
    Non-Primary)
        write_metric "mysql_galera_cluster_status{status=\"Non-Primary\"}" 0
        ;;
    Disconnected)
        write_metric "mysql_galera_cluster_status{status=\"Disconnected\"}" -1
        ;;
    *)
        write_metric "mysql_galera_cluster_status{status=\"Unknown\"}" -1
        ;;
esac

# Galera Ready State
if [[ $wsrep_ready == "ON" ]]; then
    write_metric "mysql_galera_ready{service=\"mysql\",status=\"Ready\"}" 1
else
    write_metric "mysql_galera_ready{service=\"mysql\",status=\"Not Ready\"}" 0
fi

# Galera Connected State
if [[ $wsrep_connected == "ON" ]]; then
    write_metric "mysql_galera_connected{service=\"mysql\",status=\"Connected\"}" 1
else
    write_metric "mysql_galera_connected{service=\"mysql\",status=\"Disconnected\"}" 0
fi

################
################

################
# Logs Checks  #
################

# Function to truncate a string to a specified length
truncate_string() {
    local string="$1"
    local length="$2"
    if [ ${#string} -gt $length ]; then
        echo "${string:0:$length}..."
    else
        echo "$string"
    fi
}

# Associative array for logs: [service_name]="log_path|patterns"
declare -A log_files=(
    ["soa"]="/var/seamless/log/soa-integration/soa-integration.log|^.*exception.* ^.*Exception.* ^.*EXCEPTION.* \"^.*Connect timed out.*$\" \"^.*Read timed out.*$\" \"^.*SocketTimeoutException.*$\""
    ["nginx"]="/var/seamless/log/nginx/error.log|\"^.*Connection\\stimed\\sout.*$\" \"^.*error.*$\""
    ["is"]="/var/seamless/log/integration-services/integration-services.log|\"^.*Illegal\\scharacter\\sin\\squery\\sat.*$\" \"^.*javax.net.ssl.SSLHandshakeException.*$\" \"^.*responseCodeDescription\":\"Failed\\sto\\sreserve\\sinventory.*$\" \"^.*failed:\\sconnect\\stimed\\sout.*$\" \"^.*Internal\\sserver\\serror.*$\" \"^.*error\\soccurred\\swhile\\screate\\sZDS\\sorder.*$\" \"^.*responseCodeDescription\":\"Unable\\sto\\sacquire\\sJDBC\\sConnection.*$\" \"^.*responseCodeDescription\":\"Internal\\serror\\sencountered.*$\" \"^.*zds\\sapigw\\serror/s403.*$\" \"^.*Internal\\sError.*$\" \"^.*ApiGw\\sreturned\\sincorrect\\sresponse.*$\" \"^.*Customer\\sdoes\\snot\\shave\\sEIO\\sevent.*$\" \"^.*New\\sorder\\scannot\\sbe\\screated\\swhile\\scurrent.*$\""
    ["dms"]="/var/seamless/log/dealer-management-system/dealer-management-system.log|^.*exception.* ^.*Exception.* ^.*EXCEPTION.* \"^.*connect timed out.*$\" \"^.*Read timed out.*$\" \"^.*SocketTimeoutException.*$\""
    ["vfo"]="/var/seamless/log/vfo-link/vfo-link.log|^.*exception.* ^.*Exception.* ^.*EXCEPTION.* \"^.*connect timed out.*$\" \"^.*Read timed out.*$\" \"^.*SocketTimeoutException.*$\" \"^.*Internal Server Error.*$\" \"^.*Error.*$\" \"^.*Connect Timeout.*$\""
    ["identity_ms"]="/var/seamless/log/identity-management/ers-identity-management-0/identity-management.log|^.*exception.*$ ^.*Exception.*$ ^.*EXCEPTION.*$ \"^.*connect timed out.*$\" \"^.*Read timed out.*$\" \"^.*SocketTimeoutException.*$\" \"^.*Internal Error.*$\""
    ["oms"]="/var/seamless/log/order-management-system/order-management-system.log|!\"^.*CreateOrder_en_US.*\" ^.*ERROR.* ^.*exception.* ^.*Exception.* ^.*EXCEPTION.*"
    ["accountsystem"]="/var/seamless/log/account-management-service/account-management-service.log|^.*exception.* ^.*Exception.* ^.*EXCEPTION.*"
    ["access_ms"]="/var/seamless/log/access-management-system/access-management-system.log|^.*exception.* ^.*Exception.* ^.*EXCEPTION.*"
    ["contract_ms"]="/var/seamless/log/contract-management-system/contract-management-system.log|^.*exception.*$ ^.*Exception.*$ ^.*EXCEPTION.*$"
    ["notification_manager"]="/var/seamless/log/notification-manager/notification-manager.log|^.*exception.*$ ^.*Exception.*$ ^.*EXCEPTION.*$"
)

# Function to check logs and write metrics
check_logs() {
    local service=$1
    local log_info=$2
    local log_file=$(echo "$log_info" | cut -d '|' -f 1)
    local patterns=$(echo "$log_info" | cut -d '|' -f 2)

#    echo "Checking log for $service with patterns $patterns"  # Debug print

    # Generate log check command
    local log_check_cmd="/usr/lib64/nagios/plugins/check_logwarn -p $log_file $patterns"
    local log_output=$($log_check_cmd)
    local log_count=$(echo "$log_output" | grep -vc OK)

    # Write metrics
    if [[ $log_count -ge 1 ]]; then
        truncated_logs=$(truncate_string "$log_output" 100)
        write_metric "${service}_error_logs{service=\"$service\",status=\"Error\",description=\"$truncated_logs\"}" "$log_count"
    else
        write_metric "${service}_error_logs{service=\"$service\",status=\"Ok\",description=\"No Error found\"}" 0
    fi
}

# Iterate through the log files and check logs
for service in "${!log_files[@]}"; do
    check_logs "$service" "${log_files[$service]}"
done

#################
# Process Check #
#################

# Function to check process status
check_process() {
    local process_name=$1
    local process_count=$(pgrep -f "$process_name" | wc -l)
    if [[ $process_count -ge 1 ]]; then
        write_metric "${process_name}_process_status{process=\"$process_name\",status=\"Running\"}" "$process_count"
    else
        write_metric "${process_name}_process_status{process=\"$process_name\",status=\"Stopped\"}" "$process_count"
    fi
}

# Checking processes
processes=("java" "nginx" "mysql" "docker" "cron" "rsyslogd")
for process in "${processes[@]}"; do
    check_process "$process"
done

################
# Other checks #
################

ntp=$(timedatectl show -p NTPSynchronized --value)

# NTP status
if [[ $ntp == "yes" ]]; then
    write_metric "outbound_service{service=\"NTP\",status=\"Synched\",description=\"NTP is Synched\"}" 1
else
    write_metric "outbound_service{service=\"NTP\",status=\"Not Synched\",description=\"NTP is not synched\"}" 0
fi

echo "Completed"