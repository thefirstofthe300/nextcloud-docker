#!/bin/bash
set -eu

# version_greater A B returns whether A > B
version_greater() {
    [ "$(printf '%s\n' "$@" | sort -t '.' -n -k1,1 -k2,2 -k3,3 -k4,4 | head -n 1)" != "$1" ]
}

# return true if specified directory is empty
directory_empty() {
    [ -z "$(ls -A "$1/")" ]
}

run_as() {
    if [ "$(id -u)" = 0 ]; then
        su -p "$user" -s /bin/sh -c "$1"
    else
        sh -c "$1"
    fi
}

# Execute all executable files in a given directory in alphanumeric order
run_path() {
    local hook_folder_path="/docker-entrypoint-hooks.d/$1"
    local return_code=0

    if ! [ -d "${hook_folder_path}" ]; then
        echo "=> Skipping the folder \"${hook_folder_path}\", because it doesn't exist"
        return 0
    fi

    echo "=> Searching for scripts (*.sh) to run, located in the folder: ${hook_folder_path}"

    (
        find "${hook_folder_path}" -type f -maxdepth 1 -iname '*.sh' -print | sort | while read -r script_file_path; do
            if ! [ -x "${script_file_path}" ]; then
                echo "==> The script \"${script_file_path}\" was skipped, because it didn't have the executable flag"
                continue
            fi

            echo "==> Running the script (cwd: $(pwd)): \"${script_file_path}\""

            run_as "${script_file_path}" || return_code="$?"

            if [ "${return_code}" -ne "0" ]; then
                echo "==> Failed at executing \"${script_file_path}\". Exit code: ${return_code}"
                exit 1
            fi

            echo "==> Finished the script: \"${script_file_path}\""
        done
    )
}

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    local varValue=$(env | grep -E "^${var}=" | sed -E -e "s/^${var}=//")
    local fileVarValue=$(env | grep -E "^${fileVar}=" | sed -E -e "s/^${fileVar}=//")
    if [ -n "${varValue}" ] && [ -n "${fileVarValue}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    if [ -n "${varValue}" ]; then
        export "$var"="${varValue}"
    elif [ -n "${fileVarValue}" ]; then
        export "$var"="$(cat "${fileVarValue}")"
    elif [ -n "${def}" ]; then
        export "$var"="$def"
    fi
    unset "$fileVar"
}

run_as() {
    if [ "$(id -u)" = 0 ]; then
        su -p "$user" -s /bin/sh -c "$1"
    else
        sh -c "$1"
    fi
}

if expr "$1" : "apache" 1>/dev/null; then
    if [ -n "${APACHE_DISABLE_REWRITE_IP+x}" ]; then
        a2disconf remoteip
    fi
fi

if expr "$1" : "apache" 1>/dev/null || [ "$1" = "php-fpm" ] || [ "${NEXTCLOUD_UPDATE:-0}" -eq 1 ]; then
    uid="$(id -u)"
    gid="$(id -g)"
    if [ "$uid" = '0' ]; then
        case "$1" in
            apache2*)
                user="${APACHE_RUN_USER:-www-data}"
                group="${APACHE_RUN_GROUP:-www-data}"

                # strip off any '#' symbol ('#1000' is valid syntax for Apache)
                user="${user#'#'}"
                group="${group#'#'}"
                ;;
            *) # php-fpm
                user='www-data'
                group='www-data'
                ;;
        esac
    else
        user="$uid"
        group="$gid"
    fi

    if [ -n "${REDIS_HOST+x}" ]; then

        echo "Configuring Redis as session handler"
        {
            file_env REDIS_HOST_PASSWORD
            echo 'session.save_handler = redis'
            # check if redis host is an unix socket path
            if [ "$(echo "$REDIS_HOST" | cut -c1-1)" = "/" ]; then
              if [ -n "${REDIS_HOST_PASSWORD+x}" ]; then
                echo "session.save_path = \"unix://${REDIS_HOST}?auth=${REDIS_HOST_PASSWORD}\""
              else
                echo "session.save_path = \"unix://${REDIS_HOST}\""
              fi
            # check if redis password has been set
            elif [ -n "${REDIS_HOST_PASSWORD+x}" ]; then
                echo "session.save_path = \"tcp://${REDIS_HOST}:${REDIS_HOST_PORT:=6379}?auth=${REDIS_HOST_PASSWORD}\""
            else
                echo "session.save_path = \"tcp://${REDIS_HOST}:${REDIS_HOST_PORT:=6379}\""
            fi
            echo "redis.session.locking_enabled = 1"
            echo "redis.session.lock_retries = -1"
            # redis.session.lock_wait_time is specified in microseconds.
            # Wait 10ms before retrying the lock rather than the default 2ms.
            echo "redis.session.lock_wait_time = 10000"
        } > /usr/local/etc/php/conf.d/redis-session.ini
    fi
fi

chown -R $user:$group /var/www/html

if [[ "$(run_as 'php /var/www/html/occ status' 2>&1 | grep "Nextcloud is not installed")" != "" ]]; then
    echo "Setting up for install"

    rm /var/www/html/config/config.php
    cp -r /usr/src/nextcloud/config/* /var/www/html/config

    if [ -n "${NEXTCLOUD_ADMIN_USER+x}" ] && [ -n "${NEXTCLOUD_ADMIN_PASSWORD+x}" ]; then
        # shellcheck disable=SC2016
        install_options="-n --admin-user $NEXTCLOUD_ADMIN_USER --admin-pass $NEXTCLOUD_ADMIN_PASSWORD"

        file_env MYSQL_DATABASE
        file_env MYSQL_PASSWORD
        file_env MYSQL_USER
        file_env POSTGRES_DB
        file_env POSTGRES_PASSWORD
        file_env POSTGRES_USER

        install=false
        if [ -n "${SQLITE_DATABASE+x}" ]; then
            echo "Installing with SQLite database"
            # shellcheck disable=SC2016
            install_options=$install_options" --database-name $SQLITE_DATABASE"
            install=true
        elif [ -n "${MYSQL_DATABASE+x}" ] && [ -n "${MYSQL_USER+x}" ] && [ -n "${MYSQL_PASSWORD+x}" ] && [ -n "${MYSQL_HOST+x}" ]; then
            echo "Installing with MySQL database"
            # shellcheck disable=SC2016
            install_options=$install_options" --database mysql --database-name $MYSQL_DATABASE --database-user $MYSQL_USER --database-pass $MYSQL_PASSWORD --database-host $MYSQL_HOST"
            install=true
        elif [ -n "${POSTGRES_DB+x}" ] && [ -n "${POSTGRES_USER+x}" ] && [ -n "${POSTGRES_PASSWORD+x}" ] && [ -n "${POSTGRES_HOST+x}" ]; then
            echo "Installing with PostgreSQL database"
            # shellcheck disable=SC2016
            install_options=$install_options" --database=pgsql --database-name=$POSTGRES_DB --database-user=$POSTGRES_USER --database-pass=$POSTGRES_PASSWORD --database-host=$POSTGRES_HOST"
            install=true
        fi

        if [ "$install" = true ]; then
            run_path pre-installation

            echo "Starting nextcloud installation"
            max_retries=10
            try=0
            echo "Install with options: $install_options"
            until run_as "php /var/www/html/occ maintenance:install $install_options" || [ "$try" -gt "$max_retries" ]
            do
                echo "Retrying install..."
                try=$((try+1))
                sleep 10s
            done
            if [ "$try" -gt "$max_retries" ]; then
                echo "Installing of nextcloud failed!"
                exit 1
            fi
            if [ -n "${NEXTCLOUD_TRUSTED_DOMAINS+x}" ]; then
                echo "Setting trusted domains…"
                NC_TRUSTED_DOMAIN_IDX=1
                for DOMAIN in $NEXTCLOUD_TRUSTED_DOMAINS ; do
                    DOMAIN=$(echo "$DOMAIN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                    run_as "php /var/www/html/occ config:system:set trusted_domains $NC_TRUSTED_DOMAIN_IDX --value=$DOMAIN"
                    NC_TRUSTED_DOMAIN_IDX=$((NC_TRUSTED_DOMAIN_IDX+1))
                done
            fi

            run_path post-installation
        else
            echo "Please run the web-based installer on first connect!"
        fi
    fi
else
    echo "Starting upgrade"
    if [[ $(run_as 'php /var/www/html/occ status --output json' | jq .needsDbUpgrade) == true ]]; then
        echo "Upgrading database"
        run_as 'php /var/www/html/occ upgrade'
    fi

    if [[ $(run_as 'php /var/www/html/occ status --output json' | jq .maintenance) == true ]]; then
        run_as 'php /var/www/html/occ maintenance:update:htaccess'
        run_as 'php /var/www/html/occ maintenance:mode --off'
    fi
fi

exec "$@"