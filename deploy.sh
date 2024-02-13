#!/bin/bash

# Configuration variables
REPO_NAME="" # GitHub repository name
GIT_USER="" # GitHub username
REPO_URL="git@github.com:${GIT_USER}/${REPO_NAME}.git" # Repository URL
HTACCESS_PATH="web/.htaccess" # Path to .htaccess
WEBSITE_TITLE="" # Website title
WEBSITE_ADMIN_USER="" # Admin username
WEBSITE_ADMIN_PASS="" # Admin password
WEBSITE_ADMIN_EMAIL="" # Admin email
WEBSITE_URL="" # Public URL of the home of the website
DB_HOST="" # Database host
DB_NAME="" # Local database name
DB_USER="" # Local database user
DB_PASSWORD="" # Local database password
WEBSITE_WP_CLI_ROOT_PATH="web/wp" # WP-CLI root path
WEBSITE_APP_ROOT_PATH="web/app" # Website application root path

# Traitement des options
while getopts "d" opt; do
    case $opt in
        d)
            LANDO_ENABLED=true
            ;;
        *)
            echo "Option invalide : -$OPTARG" >&2
            exit 1
            ;;
    esac
done

# Fonction pour la migration
deploy_script() {

    # Clonage de Bedrock dans le répertoire actuel
    git clone https://github.com/roots/bedrock.git .

    # Initialisation du dépôt Git
    git init
    git remote add origin $REPO_URL
    git branch --set-upstream-to=origin/main master
    git pull
    rm README.md

    if [ "$LANDO_ENABLED" = true ]; then
        # Initialisation de Lando
        lando init --source cwd --recipe wordpress --webroot ./web --name ${REPO_NAME}

        # Modification du fichier .lando.yml pour utiliser PHP 8.2
        cat << EOF >> .lando.yml
services:
  appserver:
    type: php:8.2
    via: apache
    webroot: ./web
    config:
      php: config/php.ini
EOF

        lando start
        echo "Attente de la configuration des services Lando..."
        sleep 10
    else
        # Install WP-CLI
        WP_CLI_PATH=/usr/local/bin/wp
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        chmod +x wp-cli.phar
        sudo mv wp-cli.phar $WP_CLI_PATH
    fi

    # Création du fichier .env si non existant
    touch .env

    # Génération des clés salts pour WordPress
    wget https://api.wordpress.org/secret-key/1.1/salt/ -O salts.txt

    while IFS= read -r line; do
        if [[ ! -z "$line" ]]; then
            # Extraire la clé et la valeur
            KEY=$(echo "$line" | cut -d "'" -f 2)
            VALUE=$(echo "$line" | cut -d "'" -f 4 | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g')

            # Écrire dans le fichier .env
            echo "${KEY}='${VALUE}'" >> .env
        fi
    done < salts.txt

    rm salts.txt

    # Extraction des valeurs des variables en format JSON
    if [ "$LANDO_ENABLED" = true ]; then
        DB_CREDENTIALS=$(lando info --format json)

        # Utilisation de jq pour parser le JSON et récupérer les valeurs
        DB_NAME=$(echo "$DB_CREDENTIALS" | jq -r '.[] | select(.service == "database") | .creds.database')
        DB_USER=$(echo "$DB_CREDENTIALS" | jq -r '.[] | select(.service == "database") | .creds.user')
        DB_PASSWORD=$(echo "$DB_CREDENTIALS" | jq -r '.[] | select(.service == "database") | .creds.password')
        DB_HOST=$(echo "$DB_CREDENTIALS" | jq -r '.[] | select(.service == "database") | .internal_connection.host')
    fi

    # Ajouter les informations de la base de données dans le fichier .env
    echo "" >> .env
    echo "DB_NAME='${DB_NAME}'" >> .env
    echo "DB_USER='${DB_USER}'" >> .env
    echo "DB_PASSWORD='${DB_PASSWORD}'" >> .env
    echo "DB_HOST='${DB_HOST}'" >> .env

    echo "" >> .env


    echo "WP_HOME='${WEBSITE_URL}'" >> .env
    echo "WP_SITEURL='${WEBSITE_URL}/wp'" >> .env

    echo "" >> .env

    echo "WP_ENV='development'" >> .env

    echo "DB_PREFIX='wp_'" >> .env

    if [ "$LANDO_ENABLED" = true ]; then
        # Installer les dépendances avec Composer
        lando composer install

        # Reconstruire Lando si nécessaire
        lando rebuild -y

        # Installer WordPress via WP-CLI
        lando wp core install --url="${WEBSITE_URL}" --title="${WEBSITE_TITLE}" --admin_user="${WEBSITE_ADMIN_USER}" --admin_password="${WEBSITE_ADMIN_PASS}" --admin_email="${WEBSITE_ADMIN_EMAIL}" --path=${WEBSITE_WP_CLI_ROOT_PATH}
    else
        # Check if Composer is available globally, if not, install it
        if ! command -v composer &> /dev/null; then
            echo "Composer not found. Installing Composer..."
            EXPECTED_SIGNATURE=$(wget https://composer.github.io/installer.sig -O - -q)
            php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
            ACTUAL_SIGNATURE=$(php -r "echo hash_file('sha384', 'composer-setup.php');")

            if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]; then
                >&2 echo 'ERROR: Invalid installer signature'
                rm composer-setup.php
                exit 1
            fi

            php composer-setup.php --quiet
            RESULT=$?
            rm composer-setup.php

            if [ $RESULT -ne 0 ]; then
                echo "Composer installation failed. Exiting."
                exit 1
            fi

            # Move composer to a directory in your PATH
            mv composer.phar /usr/local/bin/composer
        fi

        # Install dependencies with Composer
        composer install

        # Installer WordPress via WP-CLI localement
        wp db create
        wp core install --url="${WEBSITE_URL}" --title="${WEBSITE_TITLE}" --admin_user="${WEBSITE_ADMIN_USER}" --admin_password="${WEBSITE_ADMIN_PASS}" --admin_email="${WEBSITE_ADMIN_EMAIL}"
    fi

    if [ ! -f "$HTACCESS_PATH" ]; then
        echo "Création du fichier .htaccess dans le répertoire web..."
        touch "$HTACCESS_PATH"
    
        # Write .htaccess content directly to the file
        echo "# BEGIN WordPress" >> "$HTACCESS_PATH"
        echo "<IfModule mod_rewrite.c>" >> "$HTACCESS_PATH"
        echo "RewriteEngine On" >> "$HTACCESS_PATH"
        echo "RewriteBase /" >> "$HTACCESS_PATH"
        echo "RewriteRule ^index\.php$ - [L]" >> "$HTACCESS_PATH"
        echo "RewriteRule ^wp-content/uploads/(.*) ${WEBSITE_APP_ROOT_PATH}/uploads/$1 [QSA,L]" >> "$HTACCESS_PATH"
        echo "RewriteCond %{REQUEST_FILENAME} !-f" >> "$HTACCESS_PATH"
        echo "RewriteCond %{REQUEST_FILENAME} !-d" >> "$HTACCESS_PATH"
        echo "RewriteRule . /index.php [L]" >> "$HTACCESS_PATH"
        echo "</IfModule>" >> "$HTACCESS_PATH"
        echo "# END WordPress" >> "$HTACCESS_PATH"
    else
        echo "Le fichier .htaccess existe déjà dans le répertoire web."
    fi

    # Changer l'URL du dépôt pour utiliser SSH
    git remote set-url origin ${REPO_URL}

    # Commit et push sur GitHub
    git add .
    git commit -m "Initialisation du projet WordPress avec Bedrock et Lando"
    git pull
    git push -u origin master --force

    exit
}

attendreTouche() {
    echo "Appuyez sur une touche pour continuer..."
    read -n 1 -s -r
}

deploy_script
