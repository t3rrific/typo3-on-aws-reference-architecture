#!/bin/bash
# ==============================================================================

TIMER_START=$(date +"%s")
CURRENT_DATE=$(date +"%Y%m%d")
TIMESTAMP=$(date +"%s")
PROCESS="$$"

if [ -r /tmp/environment.sh ]; then
	. /tmp/environment.sh
fi

output(){
	OUTPUT_TIMESTAMP=$(date +"%d/%b/%Y %H:%M:%S %Z")
	echo "[${OUTPUT_TIMESTAMP}] $1" | tee ~/deploy.log
}

convertsecs(){
	((h=${1}/3600))
	((m=(${1}%3600)/60))
	((s=${1}%60))
	TIME_ELAPSED=$(printf "%02d hrs %02d mins %02d secs" $h $m $s)
}

export COMPOSER_PARAMETERS="--no-ansi --no-interaction --no-progress"
export COMPOSER_HTACCESS_PROTECT="0"
export COMPOSER_NO_INTERACTION="1"
export TARGET_DIRECTORY="/var/www/typo3v11"

# ------------------------------------------------------------------------------

output "TYPO3 CMS deployment"

composer ${COMPOSER_PARAMETERS} create-project typo3/cms-base-distribution:^11 ${TARGET_DIRECTORY}
RETURN=$?
if [ ${RETURN} -ne 0 ]; then
    output "Composer \"create-project\" failed (return code: ${RETURN})"
    exit 1
fi

if [ ! -d ${TARGET_DIRECTORY}/packages ]; then
    mkdir ${TARGET_DIRECTORY}/packages
    RETURN=$?
	if [ ${RETURN} -ne 0 ]; then
        output "Unable to create folder \"${TARGET_DIRECTORY}/packages/\" (return code: ${RETURN})"
        exit 1
    fi
fi

cd ${TARGET_DIRECTORY}/

# ...
TYPO3_DB_USERNAME=$(cat ~/.my.cnf | egrep '^user=' | cut -f 2 -d '=')
TYPO3_DB_PASSWORD=$(cat ~/.my.cnf | egrep '^password=' | cut -f 2 -d '=')
TYPO3_DB_HOST=$(cat ~/.my.cnf | egrep '^host=' | cut -f 2 -d '=')
TYPO3_DB_DATABASE=$(cat ~/.my.cnf | egrep '^database=' | cut -f 2 -d '=')

composer config repositories.packages '{"type": "path", "url": "packages/*"}'
touch public/FIRST_INSTALL

export TYPO3_INSTALL_DB_DRIVER="pdo_mysql"
export TYPO3_INSTALL_DB_USER="${TYPO3_DB_USERNAME}"
export TYPO3_INSTALL_DB_PASSWORD="${TYPO3_DB_PASSWORD}"
export TYPO3_INSTALL_DB_HOST=""
export TYPO3_INSTALL_DB_PORT=""
export TYPO3_INSTALL_DB_UNIX_SOCKET=""
export TYPO3_INSTALL_DB_USE_EXISTING="no"
export TYPO3_INSTALL_DB_DBNAME="${TYPO3_DB_DATABASE}"
export TYPO3_INSTALL_ADMIN_USER="admin"
export TYPO3_INSTALL_ADMIN_PASSWORD="${TYPO3_DB_PASSWORD}"
export TYPO3_INSTALL_SITE_NAME="TYPO3 v11 LTS"
export TYPO3_INSTALL_SITE_SETUP_TYPE="site"
export TYPO3_INSTALL_WEB_SERVER_CONFIG="apache"
export TYPO3_INSTALL_SITE_BASE_URL="/"

#if [ ! -r ${CURRENT_DIRECTORY}/.env ]; then
#    echo "File not found: \"${CURRENT_DIRECTORY}/.env\""
#    exit 1
#fi

if [ -x ./vendor/bin/typo3cms ]; then
	output "Installing TYPO3"
	./vendor/bin/typo3cms install:setup
else
    output "Composer installation failed (return code: ${RETURN})"
fi

if [ ! -d ${TARGET_DIRECTORY}/public ]; then
    output "Directory not found: \"public/\""
    exit 1
else
    ln -s typo3v11/public ${TARGET_DIRECTORY}/../htdocs
    RETURN=$?
    if [ ${RETURN} -ne 0 ]; then
        output "Unable to create symbolic link: \"htdocs -> typo3v11/public/\" (return code: ${RETURN})"
        exit 1
    fi
fi

TYPO3_VERSION=$(./vendor/bin/typo3 --no-ansi --no-interaction --version)
output "${TYPO3_VERSION}"

# --------------------------------------------------------------------------------------------------

output "Deployment successfully completed"
exit 0
