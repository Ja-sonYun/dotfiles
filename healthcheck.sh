#!/bin/sh

# https://healthchecks.io/
healthcheck_request_url="http://hc-ping.com"

# PARAMETER
# - $1 : code
ping_healthcheck_server () {
    curl -fsS -m 10 --retry 5 -o /dev/null $healthcheck_request_url/$1
}

# PARAMETER
# - $1 : url
check_http_code () {
    echo `curl -sL -w "%{http_code}\\n" "$1" -o /dev/null`

}

# PARAMETER
# - $1 : url
# - $2 : code
healthcheck_http () {
    # grab only http code
    http_response_code=$(check_http_code $1)

    if [ "200" -eq $http_response_code ]; then
        echo "$1 online."
        ping_healthcheck_server $2
    else
        echo "$1 offline."
    fi
}

# PARAMETER
# - $1 : url
# - $2 : code
healthcheck_ssh () {
    ssh_connection="$(ssh $1 -o 'BatchMode=yes' -o 'ConnectionAttempts=1' true 2>&1)"

    case "$ssh_connection" in
        *"ssh_exchange_identification"*   ) echo "$1 offline" ;;
        *"Host key verification failed."* ) echo "$1 online"; ping_healthcheck_server $2 ;;
        *"Permission denied"*             ) echo "$1 online"; ping_healthcheck_server $2 ;;
        *                                 ) echo "$1 offline" ;;
    esac
}

# PARAMETER
# - $1 : url
# - $2 : code
# healthcheck_tcp () {
# }

healthcheck_http https://abex.jp.ngrok.io 1237261f-5ce9-4ab4-9ba3-29f44d15fa91
healthcheck_http https://abex1.jp.ngrok.io f0a0631d-83b6-4a79-af51-ec43476aa707
healthcheck_http https://abex.dev a18fac19-edc5-4e53-bc6e-3584428ab8e8

healthcheck_ssh "killa@1.tcp.jp.ngrok.io -p 23959" 946ae4fd-6ab3-431d-970e-f2b69b4ee79a
