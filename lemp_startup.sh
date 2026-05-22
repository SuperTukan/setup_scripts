#!/data/data/com.termux/files/usr/bin/bash
echo "🚀 Waking up the Samsung A3 Server..."

# Kill any existing stuck processes first
killall mariadbd php-fpm nginx cloudflared 2>/dev/null

# Start services
mysqld_safe -u root &
sleep 2
php-fpm
nginx
cloudflared tunnel run wpphone &

echo "✅ All systems GO. Check your domain in 30 seconds."