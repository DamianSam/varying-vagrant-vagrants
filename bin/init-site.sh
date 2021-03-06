#!/usr/bin/env bash
# Add a new site to VVV, using the following project structure
#
# wp-cli.yml  -- indicates the path to the docroot
# .gitattributes
# .gitignore
# config/*.env.php -- PHP files returning config arrays which can be merged together
# config/active-env -- the env that is currently active (e.g. vvv or production)
# database/vvv-init.sql -- the SQL that creates the DB and adds the user for the site
# database/vvv-data.sql  -- the database dump used for development, shared by developers
# docroot -- location of WordPress
# docroot/wp-config.php -- loads up the config/{env}.env.php file and extracts array into constants and global vars

set -e
cd $(dirname $0)/../

if [[ $USER != 'vagrant' ]]; then
	echo 'Error: Must run from inside Vagrant' 1>&2
	exit 1
fi

if [ -z "$1" ]; then
	echo "Error: Missing domain (sans www)" 1>&2
	exit 1
fi

domain=$1
repo_root=/srv/www/$domain
dev_domain=vvv.$domain
docroot=$repo_root/docroot
db_name=$(sed 's/[^a-z0-9][^a-z0-9]*/_/g' <<< "$domain")
db_pass=$db_name
db_user=$db_name

echo "Domain: $domain"
echo "Dev domain: $dev_domain"
echo "Database: $db_name"
echo "Repo root: $repo_root"

mkdir -p $repo_root
cd $repo_root
if [ ! -e .git ]; then
	git init
fi

mkdir -p docroot config bin database

# Set up .gitignore
git_ignores=(
	'/wp-cli.local.yml'
	'/docroot/wp-content/uploads/*'
	'/config/active-env'
	'/config/*-mine.env.php'
	'/config/*-overrides.env.php'
)
for ignored in "${git_ignores[@]}"; do
	if [ ! -e .gitignore ] || ! grep -qF "$ignored" .gitignore; then
		echo $ignored >> .gitignore
		echo "Append to .gitignore: $ignored"
	fi
done
git add -v .gitignore

# Set up .gitattributes
# TODO: much more can be added here
if [ ! -e .gitattributes ]; then
	echo '*.sql merge=binary' >> .gitattributes
fi
git add -v .gitattributes

# Set up nginx config
nginx_conf_file=config/vvv-nginx.conf
if [ ! -e $nginx_conf_file ]; then
	cat /srv/config/nginx-config/sites/local-nginx-example.conf-sample |
		sed s/testserver\\.com/$dev_domain/g |
		sed 's/^ *#.*//g' |
		sed s:/srv/www/wordpress-local:$repo_root/docroot: |
		sed '/^$/d' > $nginx_conf_file
	git add -v $nginx_conf_file
fi

# Set db init script
db_init_path=database/vvv-init.sql
printf 'CREATE DATABASE IF NOT EXISTS `%s`;\n' $db_name > $db_init_path
printf 'GRANT ALL PRIVILEGES ON `%s`.* TO "%s"@"localhost" IDENTIFIED BY "%s";\n' $db_name $db_user $db_pass >> $db_init_path
printf 'USE `%s`;\n' $db_name >> $db_init_path
git add -v $db_init_path

db_data_path=database/vvv-data.sql
if [ ! -e $db_data_path ]; then
	touch $db_data_path
	git add -v $db_data_path
fi

# Add WP-CLI configs
if [ ! -e wp-cli.yml ]; then
	printf 'path: docroot/\n' > wp-cli.yml
	printf 'url: %s\n' $domain >> wp-cli.yml
	git add -v wp-cli.yml
fi
if [ ! -e wp-cli.local.yml ]; then
	printf 'path: docroot/\n' > wp-cli.local.yml
	printf 'url: %s\n' $dev_domain >> wp-cli.local.yml
	echo "Add wp-cli.local.yml (git-ignored)"
fi

# Add hosts
domains_file=config/vvv-domains
if [ ! -e $domains_file ] || ! grep -qF "$dev_domain" $domains_file; then
	echo $dev_domain >> $domains_file
	git add -v $domains_file
fi

# Download WordPress
if [ ! -e docroot/wp-login.php ]; then
	wp core download --path=docroot
	git add docroot
fi

# Set up configs
config_file=default.env.php
if [ ! -e config/$config_file ]; then
	cp /srv/config/wordpress-config/env-defaults/$config_file config/$config_file
	sed s/__WP_CACHE_KEY_SALT__/$domain/ -i config/$config_file
	php -r '
		$src = file_get_contents( "config/default.env.php" );
		eval( file_get_contents( "https://api.wordpress.org/secret-key/1.1/salt/" ) );
		$constants = explode( " ", "AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT" );
		foreach ( $constants as $constant ) {
			$src = str_replace( "__" . $constant . "__", constant( $constant ), $src );
		}
		file_put_contents( "config/default.env.php", $src );
	'
	git add -v config/$config_file
fi

config_file=vvv.env.php
if [ ! -e config/$config_file ]; then
	cp /srv/config/wordpress-config/env-defaults/$config_file config/$config_file
	sed s/__DB_NAME__/$db_name/ -i config/$config_file
	sed s/__DB_PASSWORD__/$db_pass/ -i config/$config_file
	sed s/__DB_USER__/$db_user/ -i config/$config_file
	git add -v config/$config_file
fi

config_file=production.env.php
if [ ! -e config/$config_file ]; then
	cp /srv/config/wordpress-config/env-defaults/$config_file config/$config_file
	git add -v config/$config_file
fi

if [ ! -e docroot/wp-config.php ]; then
	cp /srv/config/wordpress-config/env-defaults/wp-config.php docroot/wp-config.php
	git add -v docroot/wp-config.php
fi

echo 'vvv' > config/active-env

# Grab Memcached and Batcache
function fetch_stable_plugin_file {
	plugin_name=$1
	plugin_file=$2
	echo -n "Fetch $plugin_file from stable plugin $plugin_name..." 1>&2
	svn_root_url="http://plugins.svn.wordpress.org/$plugin_name"
	stable_tag=$(curl -Gs "$svn_root_url/trunk/readme.txt" | grep 'Stable tag:' | sed 's/^.*:\s*//')
	echo " (stable tag: $stable_tag)" 1>&2
	if [[ $stable_tag == 'trunk' ]]; then
		svn_stable_root_url="$svn_root_url/trunk"
	else
		svn_stable_root_url="$svn_root_url/tags/$stable_tag"
	fi
	curl -Gs $svn_stable_root_url/$plugin_file
}

fetch_stable_plugin_file memcached object-cache.php > docroot/wp-content/object-cache.php
git add -v docroot/wp-content/object-cache.php
fetch_stable_plugin_file batcache advanced-cache.php > docroot/wp-content/advanced-cache.php
git add -v docroot/wp-content/advanced-cache.php
mkdir -p docroot/wp-content/mu-plugins
fetch_stable_plugin_file batcache batcache.php > docroot/wp-content/mu-plugins/batcache.php
git add -v docroot/wp-content/mu-plugins/batcache.php

# Add some convenience commands for VVV development
cat > bin/dump-db-vvv <<'BASH'
#!/usr/bin/env bash
set -e
cd $(dirname $0)/..
if [ $USER != 'vagrant' ]; then
	echo "Error: Must be run in the vagrant environment" 1>&2
	exit 1
fi
if [ $(cat config/active-env) != 'vvv' ]; then
	echo "Error: Only applicable in vvv environment" 1>&2
	exit 1
fi
wp db export database/vvv-data.sql
BASH

cat > bin/load-db-vvv <<'BASH'
#!/usr/bin/env bash
set -e
cd $(dirname $0)/..
if [ $USER != 'vagrant' ]; then
	echo "Error: Must be run in the vagrant environment" 1>&2
	exit 1
fi
if [ $(cat config/active-env) != 'vvv' ]; then
	echo "Error: Only applicable in vvv environment" 1>&2
	exit 1
fi
wp db import database/vvv-data.sql
sudo service memcached restart
BASH

chmod +x bin/dump-db-vvv
chmod +x bin/load-db-vvv
git add -v bin/dump-db-vvv
git add -v bin/load-db-vvv

echo 'Do a `vagrant reload` to recognize the new site.'
echo 'Navigate to and git-commit:'
pwd
