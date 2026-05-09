#!/data/data/com.termux/files/usr/bin/bash
# How to run on clean Termux install:
# pkg install curl -y && curl -sL http://server.abr/setup_lemp_server_v2.sh | bash

# --- 1. Infrastructure & Core Packages ---
echo "🛠️ Installing LEMP stack + OpenSSH..."
pkg update -y && pkg upgrade -y
pkg install -y nginx mariadb php php-fpm php-gd wget python python-pip nano termux-auth openssh
pip install requests

# --- 2. SSH Setup (Termux Specifics) ---
echo "🔑 Configuring SSH access..."
SSH_USER=$(whoami)
SSH_PASS=$(openssl rand -base64 16)

# Set the Termux user password non-interactively
echo -e "$SSH_PASS\n$SSH_PASS" | passwd

# Ensure the SSH directory exists and start the daemon to generate host keys
mkdir -p ~/.ssh
sshd

# --- 3. Database Initialization ---
echo "🗄️ Initializing MariaDB..."
mysql_install_db
mariadbd &

# Socket Check Loop (Max 30s)
COUNTER=0
while [ ! -S "$PREFIX/var/run/mysqld.sock" ] && [ $COUNTER -lt 30 ]; do
    sleep 1
    let COUNTER=COUNTER+1
    echo "Waiting for database socket... ($COUNTER/30)"
done

if [ ! -S "$PREFIX/var/run/mysqld.sock" ]; then
    echo "❌ ERROR: MariaDB failed to start."
    exit 1
fi

# --- 4. Credential Generation ---
DB_ROOT_PASS=$(openssl rand -base64 12)
WP_DB_NAME="wordpress"
WP_DB_USER="wp_svc_$(openssl rand -hex 3)"
WP_DB_PASS=$(openssl rand -base64 16)
WP_ADMIN_USER="dev_$(openssl rand -hex 4)"
WP_ADMIN_PASS=$(openssl rand -base64 16)

# --- 5. Database User Isolation ---
echo "🔒 Securing Database and creating Service User..."
mariadb -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS'; FLUSH PRIVILEGES;"
mariadb -u root -p"$DB_ROOT_PASS" -e "CREATE DATABASE $WP_DB_NAME;"
mariadb -u root -p"$DB_ROOT_PASS" -e "CREATE USER '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASS';"
mariadb -u root -p"$DB_ROOT_PASS" -e "GRANT ALL PRIVILEGES ON $WP_DB_NAME.* TO '$WP_DB_USER'@'localhost';"
mariadb -u root -p"$DB_ROOT_PASS" -e "FLUSH PRIVILEGES;"

# --- 6. WordPress & WP-CLI Setup ---
echo "🌐 Installing WordPress..."
mkdir -p ~/www/wordpress
cd ~/www/wordpress

curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
mv wp-cli.phar $PREFIX/bin/wp

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

# --- 7. Persistence & Automation (Termux:Boot) ---
echo "♻️ Configuring Startup Scripts..."
mkdir -p ~/.termux/boot
cat << EOF > ~/.termux/boot/start-all
#!/data/data/com.termux/files/usr/bin/bash
termux-wake-lock
sshd
mariadbd &
php-fpm
nginx
EOF
chmod +x ~/.termux/boot/start-all
cp ~/.termux/boot/start-all ~/start_server.sh

# --- 8. Final Output ---
echo "------------------------------------------------"
echo "✅ DEPLOYMENT COMPLETE"
echo "------------------------------------------------"
echo "🚀 SSH ACCESS (Port 8022)"
echo "User:     $SSH_USER"
echo "Pass:     $SSH_PASS"
echo "Command:  ssh $SSH_USER@<your_ip> -p 8022"
echo "------------------------------------------------"
echo "📝 WORDPRESS ADMIN"
echo "User:     $WP_ADMIN_USER"
echo "Pass:     $WP_ADMIN_PASS"
echo "------------------------------------------------"
echo "🔐 DATABASE PASSWORDS"
echo "DB Root:  $DB_ROOT_PASS"
echo "WP Svc:   $WP_DB_PASS"
echo "------------------------------------------------"
echo "TODO: Install Termux:Boot from the same source as Termux and run it once to allow autorun of all necessary server components"