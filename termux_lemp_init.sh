#!/data/data/com.termux/files/usr/bin/bash
# How to run on clean Termux install:
# pkg install curl -y && curl -sL https://your-server/setup_lemp_server_v3.sh | bash

set -euo pipefail

WP_ROOT="$HOME/www/wordpress"
PHP_FPM_SOCK="$PREFIX/var/run/php-fpm.sock"

# --- 1. Infrastructure & Core Packages ---
echo "🛠️ Installing LEMP stack + OpenSSH..."
pkg update -y && pkg upgrade -y
pkg install -y nginx mariadb php php-fpm php-gd wget nano termux-auth openssh openssl-tool

echo "☁️ Installing cloudflared..."
if pkg install cloudflared -y 2>/dev/null; then
    CLOUDFLARED_AVAILABLE=true
else
    echo "⚠️  cloudflared not available via pkg. Install manually: https://github.com/cloudflare/cloudflared/releases"
    CLOUDFLARED_AVAILABLE=false
fi

# --- 2. SSH Setup ---
echo "🔑 Configuring SSH access..."
SSH_PASS=$(openssl rand -base64 16)
echo -e "$SSH_PASS\n$SSH_PASS" | passwd
mkdir -p ~/.ssh
sshd

# --- 3. Database Initialization ---
echo "🗄️ Initializing MariaDB..."
mysql_install_db
mariadbd &

COUNTER=0
while [ ! -S "$PREFIX/var/run/mysqld.sock" ] && [ "$COUNTER" -lt 30 ]; do
    sleep 1
    COUNTER=$((COUNTER + 1))
    echo "Waiting for MariaDB socket... ($COUNTER/30)"
done

if [ ! -S "$PREFIX/var/run/mysqld.sock" ]; then
    echo "❌ ERROR: MariaDB failed to start."
    exit 1
fi

# --- 4. Credential Generation ---
# hex-only to avoid special characters breaking DB names, queries, or config files
DB_ROOT_PASS=$(openssl rand -hex 12)
WP_DB_NAME="wp_$(openssl rand -hex 5)"
WP_DB_USER="wp_$(openssl rand -hex 3)"
WP_DB_PASS=$(openssl rand -hex 16)
WP_ADMIN_USER="admin_$(openssl rand -hex 4)"
WP_ADMIN_PASS=$(openssl rand -hex 16)

# --- 5. Database Setup ---
echo "🔒 Securing database and creating WordPress user..."
mariadb -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"
mariadb -u root -p"$DB_ROOT_PASS" << SQL
CREATE DATABASE ${WP_DB_NAME};
CREATE USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASS}';
GRANT ALL PRIVILEGES ON ${WP_DB_NAME}.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# --- 6. WP-CLI Install ---
echo "🔧 Installing WP-CLI..."
cd /tmp
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.md5

if ! echo "$(cat wp-cli.phar.md5)  wp-cli.phar" | md5sum -c - > /dev/null 2>&1; then
    echo "❌ ERROR: WP-CLI checksum verification failed."
    exit 1
fi
rm wp-cli.phar.md5
chmod +x wp-cli.phar
mv wp-cli.phar "$PREFIX/bin/wp"

# --- 7. nginx Configuration ---
echo "🌐 Configuring nginx for WordPress + PHP-FPM..."
cat > "$PREFIX/etc/nginx/nginx.conf" << NGINXCONF
worker_processes 1;

events {
    worker_connections 1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;

    server {
        listen 8080;
        root $WP_ROOT;
        index index.php index.html;

        location / {
            try_files \$uri \$uri/ /index.php?\$args;
        }

        location ~ \.php$ {
            fastcgi_pass unix:$PHP_FPM_SOCK;
            fastcgi_index index.php;
            include fastcgi_params;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        }

        location ~ /\.ht {
            deny all;
        }
    }
}
NGINXCONF

# --- 8. PHP-FPM Startup ---
echo "⚙️ Starting PHP-FPM..."
php-fpm

COUNTER=0
while [ ! -S "$PHP_FPM_SOCK" ] && [ "$COUNTER" -lt 15 ]; do
    sleep 1
    COUNTER=$((COUNTER + 1))
    echo "Waiting for PHP-FPM socket... ($COUNTER/15)"
done

if [ ! -S "$PHP_FPM_SOCK" ]; then
    echo "❌ ERROR: PHP-FPM failed to start."
    exit 1
fi

nginx

# --- 9. WordPress Setup ---
echo "📦 Downloading and installing WordPress..."
mkdir -p "$WP_ROOT"
cd "$WP_ROOT"

wp core download --allow-root

wp config create \
    --dbname="$WP_DB_NAME" \
    --dbuser="$WP_DB_USER" \
    --dbpass="$WP_DB_PASS" \
    --allow-root

wp core install \
    --url="http://localhost:8080" \
    --title="Edge Server" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASS" \
    --admin_email="webmaster@localhost" \
    --allow-root

# --- 10. Cloudflared ---
if [ "$CLOUDFLARED_AVAILABLE" = true ]; then
    echo "☁️ Starting cloudflared quick tunnel..."
    echo "⚠️  Quick tunnel URL is temporary. For persistent tunnel: cloudflared tunnel login"
    cloudflared tunnel --url http://localhost:8080 &
fi

# --- 11. Boot Scripts (Termux:Boot) ---
echo "♻️ Configuring autostart..."
mkdir -p ~/.termux/boot

{
    echo '#!/data/data/com.termux/files/usr/bin/bash'
    echo 'termux-wake-lock'
    echo 'sshd'
    echo 'mariadbd &'
    echo 'php-fpm'
    echo 'nginx'
    if [ "$CLOUDFLARED_AVAILABLE" = true ]; then
        echo '# For a named persistent tunnel replace the line below with: cloudflared tunnel run <name>'
        echo 'cloudflared tunnel --url http://localhost:8080 &'
    fi
} > ~/.termux/boot/start-all

chmod +x ~/.termux/boot/start-all
cp ~/.termux/boot/start-all ~/start_server.sh

# --- 12. Credentials File ---
CRED_FILE="$HOME/.server_credentials"
cat > "$CRED_FILE" << CREDS
# Server Credentials — $(date)
# Treat this file as a secret.

SSH_PASS=$SSH_PASS
SSH_PORT=8022

DB_ROOT_PASS=$DB_ROOT_PASS
WP_DB_NAME=$WP_DB_NAME
WP_DB_USER=$WP_DB_USER
WP_DB_PASS=$WP_DB_PASS

WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_PASS=$WP_ADMIN_PASS
CREDS
chmod 600 "$CRED_FILE"

# --- 13. Final Output ---
echo ""
echo "------------------------------------------------"
echo "✅ DEPLOYMENT COMPLETE"
echo "------------------------------------------------"
echo "🚀 SSH ACCESS (Port 8022)"
echo "    Pass:    $SSH_PASS"
echo "    Command: ssh user@<your_ip> -p 8022"
echo "------------------------------------------------"
echo "📝 WORDPRESS ADMIN"
echo "    URL:     http://localhost:8080/wp-admin"
echo "    User:    $WP_ADMIN_USER"
echo "    Pass:    $WP_ADMIN_PASS"
echo "------------------------------------------------"
echo "🔐 DATABASE"
echo "    Root:    $DB_ROOT_PASS"
echo "    WP svc:  $WP_DB_PASS"
echo "------------------------------------------------"
echo "📁 Credentials saved to: $CRED_FILE"
echo "------------------------------------------------"
echo "TODO: Install Termux:Boot from F-Droid (same source as Termux)"
echo "      Run it once to enable autostart on device boot."
if [ "$CLOUDFLARED_AVAILABLE" = true ]; then
    echo "TODO: For a persistent cloudflared tunnel:"
    echo "      cloudflared tunnel login"
    echo "      cloudflared tunnel create myserver"
    echo "      Update ~/start_server.sh and ~/.termux/boot/start-all"
fi
echo "------------------------------------------------"