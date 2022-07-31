#!/bin/bash
# ==============================================================================

TIMER_START=$(date +"%s")
CURRENT_DATE=$(date +"%Y%m%d")
TIMESTAMP=$(date +"%s")
PROCESS="$$"

#export LC_CTYPE=en_US.UTF-8
#export LC_ALL=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

if [ -r /tmp/environment.sh ]; then
	. /tmp/environment.sh
fi

output(){
	OUTPUT_TIMESTAMP=$(date +"%d/%b/%Y %H:%M:%S %Z")
	echo "[${OUTPUT_TIMESTAMP}] $1" | tee --append /var/log/setup.log
}

convertsecs(){
	((h=${1}/3600))
	((m=(${1}%3600)/60))
	((s=${1}%60))
	TIME_ELAPSED=$(printf "%02d hrs %02d mins %02d secs" $h $m $s)
}

# ------------------------------------------------------------------------------
# ...

USERID=$(id -u)
if [ ${USERID} -ne 0 ]; then
	output "\"root\" permissions are required to run this script."
	exit 1
fi

# ------------------------------------------------------------------------------
# ...

output "Configuring locales"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen --purge en_US.UTF-8 > /dev/null
OUTPUT=$(dpkg-reconfigure --frontend=noninteractive locales 2>&1 > /dev/null)
update-locale LANG=en_US.UTF-8

output "Enabling \"contrib\" and \"non-free\" Debian packages"
sed -i -e 's/ main$/ main contrib non-free/g' /etc/apt/sources.list
apt-get --yes -qq update

output "Removing Debian package \"nano\""
apt-get --yes -qq remove nano > /dev/null

echo "content-disposition = on" >> /etc/wgetrc

output "Configuring log rotation"
cat /etc/logrotate.d/rsyslog | egrep -v "mail\.log|auth\.log" | tee /etc/logrotate.d/rsyslog.new > /dev/null
mv /etc/logrotate.d/rsyslog.new /etc/logrotate.d/rsyslog

cat <<EOF > /etc/logrotate.d/mail
/var/log/mail.log
{
    rotate 9999
    daily
    dateext
    missingok
    notifempty
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

cat <<EOF > /etc/logrotate.d/auth
/var/log/auth.log
{
    rotate 9999
    daily
    dateext
    missingok
    notifempty
    compress
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

# chrony
output "Configuring service \"chrony\""
cat /etc/chrony/chrony.conf | sed 's/^\(pool .*\)$/# \1/g' > /etc/chrony/chrony.conf.new
mv /etc/chrony/chrony.conf.new /etc/chrony/chrony.conf
output "Restarting service \"chrony\""
systemctl restart chrony
echo 'server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' > /etc/chrony/sources.d/aws-ntp-server.sources
chronyc reload sources > /dev/null

# Automatic Debian updates
output "Configure automatic Debian updates"

cat <<EOF | debconf-set-selections
apt-listchanges	apt-listchanges/frontend	select	mail
apt-listchanges	apt-listchanges/which	select	both
apt-listchanges	apt-listchanges/no-network	boolean	false
apt-listchanges	apt-listchanges/email-address	string	root
apt-listchanges	apt-listchanges/email-format	select	text
apt-listchanges	apt-listchanges/headers	boolean	false
apt-listchanges	apt-listchanges/reverse	boolean	false
apt-listchanges	apt-listchanges/save-seen	boolean	true
apt-listchanges	apt-listchanges/confirm	boolean	false
EOF

cat /etc/apt/apt.conf.d/50unattended-upgrades | sed 's/^\(\/\/Unattended-Upgrade::Mail[[:space:]].*\)$/\1\nUnattended-Upgrade::Mail "root";/g' > /etc/apt/apt.conf.d/50unattended-upgrades.new
mv /etc/apt/apt.conf.d/50unattended-upgrades.new /etc/apt/apt.conf.d/50unattended-upgrades

cat <<EOF | debconf-set-selections
unattended-upgrades	unattended-upgrades/enable_auto_updates	boolean	true
EOF

# Clean-up
output "Cleaning up Debian repository and downloaded packages"
apt-get --yes autoremove 2>&1 > /dev/null
apt-get --yes purge 2>&1 > /dev/null
apt-get --yes clean 2>&1 > /dev/null
apt-get --yes autoclean 2>&1 > /dev/null

# ------------------------------------------------------------------------------

output "System-specific configuration"

# mail aliases
# ...
#newaliases

# postfix
# ...

# set mail name
if [ ! "${MAILNAME}" = "" ]; then
	output "Setting mailname: ${MAILNAME}"
	echo "${MAILNAME}" > /etc/mailname
fi

output "Restarting service \"postfix\""
systemctl restart postfix

# ------------------------------------------------------------------------------
# Apache + PHP + Composer

PHP_VERSION=$(php --version | head -1 | sed 's/^PHP \([^ ]*\).*$/\1/g' | sed 's/^\([0-9]*\.[0-9]*\.[0-9]*\).*/\1/')
PHP_VERSION=$(echo "${PHP_VERSION}" | egrep '^[0-9]*\.[0-9]*\.[0-9]*$' | cut -f 1,2 -d '.')

output "Configuring Apache web server"
cat /etc/apache2/conf-available/security.conf | sed "s/^ServerTokens\(.*\)$/#ServerTokens\1\nServerTokens Prod/g" | egrep -v '#ServerTokens.*' | sed "s/^ServerSignature\(.*\)$/#ServerSignature\1\nServerSignature Off/g" | egrep -v '#ServerSignature.*' > /etc/apache2/conf-available/security.conf.new
mv /etc/apache2/conf-available/security.conf.new /etc/apache2/conf-available/security.conf

a2enmod rewrite headers expires fcgid suexec actions 2>&1 >/dev/null

cd /var/www/
rm -rf html

mkdir cgi-bin etc log

output "PHP version ${PHP_VERSION}"
if [ -r /etc/php/${PHP_VERSION}/cgi/php.ini ]; then
	output "Creating customized php.ini file"
	cat /etc/php/${PHP_VERSION}/cgi/php.ini | sed "s/^expose_php\(.*\)$/expose_php = Off/g" | sed "s/^max_execution_time\(.*\)$/max_execution_time = 240/g" | sed "s/^\(;max_input_vars.*\)$/\1\nmax_input_vars = 1500/g" | sed 's/^post_max_size\(.*\)$/post_max_size = 10M/g' | sed 's/^upload_max_filesize\(.*\)$/upload_max_filesize = 10M/g' | sed 's/^\(.*\)always_populate_raw_post_data\(.*\)$/always_populate_raw_post_data = -1/g' > ./etc/php.ini
fi

if [ ! -r ./cgi-bin/php.fcgi ]; then
	output "Creating FCGI wrapper"
	echo '#!/bin/sh' > /tmp/php.fcgi
	echo -e "export PHP_FCGI_CHILDREN=4\nexport PHP_FCGI_MAX_REQUESTS=200\nexport PHPRC=\"/var/www/etc/php.ini\"\nexec /usr/bin/php-cgi" >> /tmp/php.fcgi
	mv /tmp/php.fcgi ./cgi-bin/php.fcgi
	chmod 755 ./cgi-bin/php.fcgi
fi

output "Disabling default site in Apache"
a2dissite 000-default 2>&1 >/dev/null

if [ -r /opt/deployment/example01/build/debian11/apache2.conf ]; then
	output "Copying Apache virtual host configuration"
	cp /opt/deployment/example01/build/debian11/apache2.conf ./etc/

	output "Creating symbolic link \"typo3.conf\""
	ln -s /var/www/etc/apache2.conf /etc/apache2/sites-available/typo3.conf

	output "Enabling TYPO3 site in Apache"
	a2ensite typo3 2>&1 >/dev/null
fi

chown -R ${USERNAME}: .
chmod 755 .

cat <<EOF >> /etc/apache2/envvars
# Make hostname available
export HOSTNAME=\$(hostname --short)
EOF

output "Restarting Apache web server"
systemctl restart apache2

output "Installing Composer"
export COMPOSER_HOME="${HOME}/.config/composer";
curl -sS https://getcomposer.org/installer | php -- --quiet --install-dir=/usr/local/bin --filename=composer

# ------------------------------------------------------------------------------
# MySQL/MariaDB

output "Creating database: ${DATABASE}"
mysql -e "CREATE DATABASE ${DATABASE}"

output "Creating database user: ${USERNAME}"
mysql -e "CREATE USER '${USERNAME}'@'%' IDENTIFIED BY '${PASSWORD}'"

output "Configuring database access permissions"
mysql -e "GRANT ALL PRIVILEGES ON ${DATABASE}.* TO '${USERNAME}'@'%'"
mysql -e "FLUSH PRIVILEGES"

output "Creating .my.cnf file for user: ${USERNAME}"

echo -e "[client]\nuser=${USERNAME}\npassword=${PASSWORD}\n\n[mysql]\ndatabase=${DATABASE}" > /home/${USERNAME}/.my.cnf
chown ${USERNAME}: /home/${USERNAME}/.my.cnf
chmod 600 /home/${USERNAME}/.my.cnf

# ------------------------------------------------------------------------------
# TYPO3 CMS deployment

if [ -r /opt/deployment/example01/build/typo3v11/cms-base-distribution/deploy.sh ]; then
	# USERNAME: see file /tmp/environment.sh
	output "Executing TYPO3 deployment script"
	su - ${USERNAME} -c ". /opt/deployment/example01/build/typo3v11/cms-base-distribution/deploy.sh"
    RETURN=$?
    if [ ${RETURN} -eq 0 ]; then
        echo "No errors (return code: ${RETURN})"
	else
        echo "Deployment failed (return code: ${RETURN})"
    fi
fi

# ------------------------------------------------------------------------------
# System summary

SYSTEM_LSB_DESCRIPTION=$(lsb_release --short --description)
SYSTEM_UNAME=$(uname -a)
VERSION_DEBIAN=$(cat /etc/debian_version)
VERSION_APACHE=$(/usr/sbin/apache2ctl -v | grep version | sed 's/Server version: //g')
VERSION_PHP=$(php -v | head -1 | cut -f 1,2 -d ' ' | cut -f 1 -d '~' | cut -f 1 -d '-')
VERSION_COMPOSER=$(export COMPOSER_ALLOW_SUPERUSER=1 ; composer --no-ansi --version)

# output ...

# ------------------------------------------------------------------------------
# Deployment finished

TIMER_STOP=$(date +"%s")
let TIME_ELAPSED=TIMER_STOP-TIMER_START
convertsecs ${TIME_ELAPSED}
#output "Script $0 finished (${TIME_ELAPSED})"

UPTIME=$(echo "($(date +"%s") - $(date +"%s" -d "$(uptime -s)"))" | bc)
convertsecs ${UPTIME}
output "Build script finished (time elapsed since system launch: ${TIME_ELAPSED})"

#output "Initiating system reboot"
#reboot

# ------------------------------------------------------------------------------
