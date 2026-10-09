#!/bin/bash

# Цвета для вывода
GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
NC='\033[0m' # No Color

[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ скрипту нужны root права ${NC}"; exit 1; }

DOMAIN=$1
vless_url=$2

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ Ошибка: домен не задан.${NC}"
    exit 1
fi

if [ -z "$vless_url" ]; then
    echo -e "${RED}❌ Ошибка: конфиг vless не задан.${NC}"
    exit 1
fi

if [[ "$vless_url" != vless://* ]]; then
    echo -e "${RED}❌ Ошибка: Неверный формат vless-ссылки.${NC}"
    exit 1
fi

# Функция URL-декодинга
urldecode() {
    printf '%b' "${1//%/\\x}"
}

url_body="${vless_url#vless://}"

node_name_enc="${url_body##*#}"
node_nameVL="$(urldecode "$node_name_enc")"

url_body="${url_body%%#*}"

uuidVL="${url_body%@*}"
host_port_query="${url_body#*@}"

addressVL="${host_port_query%%:*}"
restVL="${host_port_query#*:}"
portVL="${restVL%%\?*}"

# Если порт не распарсился — по умолчанию 443
if [ -z "$portVL" ] || ! [[ "$portVL" =~ ^[0-9]+$ ]]; then
    portVL=443
fi

query_string="${restVL#*\?}"

# Разбор параметров в ассоциативный массив
declare -A params
IFS='&' read -ra pairs <<< "$query_string"
for pair in "${pairs[@]}"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    params["$key"]="$(urldecode "$value")"
done

# Вывод:
echo -e "${YEL}== Основное ==${NC}"
echo "UUID: $uuidVL"
echo "Address: $addressVL"
echo "Port: $portVL"
echo "Node Name: $node_nameVL"

echo ""
echo -e "${YEL}== Параметры ==${NC}"
TYPE="${params[type]}"; echo "TYPE=$TYPE"
FP="${params[fp]}"; echo "FP=$FP"
SNI="${params[sni]}"; echo "SNI=$SNI"
SPX="${params[spx]}"; echo "SPX=$SPX"
PBK="${params[pbk]}"; echo "PBK=$PBK"
SECURITY="${params[security]}"; echo "SECURITY=$SECURITY"
FLOW="${params[flow]}"; echo "FLOW=$FLOW"
SID="${params[sid]}"; echo "SID=$SID"

echo -e "\n${YEL}Обновление и установка необходимых пакетов...${NC}"
apt-get update && apt-get install curl jq dnsutils openssl nginx certbot wget tar -y
systemctl enable --now nginx

LOCAL_IP=$(hostname -I | awk '{print $1}')
DNS_IP=$(dig +short "$DOMAIN" | grep '^[0-9]')

if [ "$LOCAL_IP" != "$DNS_IP" ]; then
    echo -e "${RED}❌ Внимание: IP-адрес ($LOCAL_IP) не совпадает с A-записью $DOMAIN ($DNS_IP).${NC}"
    echo -e "${YEL}Правильно укажите одну A-запись для вашего домена в ДНС - $LOCAL_IP ${NC}"
    
    read -p "Продолжить на ваш страх и риск? (y/N): " choice

    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo -e "${RED}Выполнение скрипта прервано.${NC}"
        exit 1
    fi
    echo -e "${YEL}Продолжение выполнения скрипта...${NC}"
fi

# Включаем BBR
bbr=$(sysctl -a | grep net.ipv4.tcp_congestion_control)
if [ "$bbr" = "net.ipv4.tcp_congestion_control = bbr" ]; then
    echo -e "${GRN}BBR уже запущен${NC}"
else
    echo "net.core.default_qdisc=fq" > /etc/sysctl.d/999-autoXRAY.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/999-autoXRAY.conf
    sysctl --system
    echo -e "${GRN}BBR активирован${NC}"
fi

cat <<EOF > /etc/security/limits.d/99-autoXRAY.conf
*       soft    nofile  1048576
*       hard    nofile  1048576
root    soft    nofile  1048576
root    hard    nofile  1048576
EOF
ulimit -n 65535
echo -e "${GRN}Лимиты применены. Текущий ulimit -n: $(ulimit -n) ${NC}"

# Создание директории сайта
WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH"

# Генерируем сайт маскировку (с проверкой скачивания)
echo -e "${YEL}Скачивание и запуск генератора страницы-заглушки...${NC}"
GEN_PAGE_SCRIPT=$(mktemp)
if ! curl -sL -o "$GEN_PAGE_SCRIPT" "https://github.com/FlagmanAlex/autoXRAY/raw/refs/heads/main/test/gen_page2.sh"; then
    echo -e "${RED}❌ Не удалось скачать gen_page2.sh. Проверьте подключение к GitHub.${NC}"
    rm -f "$GEN_PAGE_SCRIPT"
    exit 1
fi
if ! bash "$GEN_PAGE_SCRIPT" "$WEB_PATH"; then
    echo -e "${RED}❌ Ошибка при выполнении gen_page2.sh.${NC}"
    rm -f "$GEN_PAGE_SCRIPT"
    exit 1
fi
rm -f "$GEN_PAGE_SCRIPT"
echo -e "${GRN}✅ Страница-заглушка сгенерирована.${NC}"

# Установка Xray
echo -e "${YEL}Установка Xray...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# Блок CERTBOT - START

# Определяем путь к конфигу nginx
if [ -f /etc/nginx/sites-available/default ]; then
    CONFIG_PATH="/etc/nginx/sites-available/default"
    echo -e "${GRN}Обнаружена стандартная сборка nginx. ${NC}"
elif [ -f /etc/nginx/conf.d/default.conf ]; then
    CONFIG_PATH="/etc/nginx/conf.d/default.conf"
    echo -e "${YEL}Обнаружена нестандартная сборка nginx. Предварительная настройка NGINX для CERTBOT ${NC}"
    mkdir -p /var/www/html

    # Записываем временный конфиг
    cat <<EOF > "$CONFIG_PATH"
server {
    listen 80 default_server;
    server_name _;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    systemctl reload nginx
else
    echo -e "${RED}Не найден ни один default конфиг nginx${NC}"
    exit 1
fi

# Проверяем, что порт 80 свободен (не занят другим процессом)
if ss -tlnp | grep -q ':80 ' && ! ss -tlnp | grep -q 'nginx'; then
    echo -e "${RED}❌ Порт 80 занят другим процессом. Certbot не сможет получить сертификат.${NC}"
    ss -tlnp | grep ':80 '
    exit 1
fi

mkdir -p /var/lib/xray/cert/

# Запускаем certbot (копирование сертификатов через deploy-hook)
echo -e "${YEL}Получение сертификата Let's Encrypt для $DOMAIN...${NC}"
certbot certonly --webroot -w /var/www/html \
  -d "$DOMAIN" \
  -m "mail@$DOMAIN" \
  --agree-tos --non-interactive \
  --deploy-hook "systemctl reload nginx; cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem; cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem; chmod 744 /var/lib/xray/cert/privkey.pem; chmod 744 /var/lib/xray/cert/fullchain.pem; systemctl restart xray"

RET=$?

if [ $RET -eq 0 ]; then
  echo -e "\n${GRN}========================================"
  echo    "✅  Команда certbot успешно выполнена"
  echo    "✅  Сертификат https от letsencrypt ПОЛУЧЕН"
  echo    "========================================"
  echo -e "${NC}"
else
  echo -e "\n${RED}========================================"
  echo    "❌  CERTBOT ЗАВЕРШИЛСЯ С ОШИБКОЙ"
  echo    "❌  Сертификат https от letsencrypt НЕ ПОЛУЧЕН!"
  echo    "❌  Смотрите выше логи процесса получения сертификата"
  echo    "❌  Код возврата: $RET"
  echo    "========================================"
  echo -e "${NC}"
  exit 1
fi
# Блок CERTBOT - END

# Конфиг nginx (для моста — только сокет и страница подписки)
path_subpage=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)

bash -c "cat > $CONFIG_PATH" <<EOF
server {
    server_name $DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl http2 proxy_protocol;
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;
    
    root /var/www/$DOMAIN;
    index index.php index.html;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    ssl_certificate "/etc/letsencrypt/live/$DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/letsencrypt/live/$DOMAIN/privkey.pem";

    location = /${path_subpage}.json {
        add_header profile-title "base64:YXV0b1hSQVk=";
        add_header routing "happ://routing/onadd/eyJOYW1lIjoiYXV0b1hSQVkiLCJHbG9iYWxQcm94eSI6InRydWUiLCJSb3V0ZU9yZGVyIjoiYmxvY2stcHJveHktZGlyZWN0IiwiUmVtb3RlRE5TVHlwZSI6IkRvSCIsIlJlbW90ZUROU0RvbWFpbiI6Imh0dHBzOi8vZG5zLmdvb2dsZS9kbnMtcXVlcnkiLCJSZW1vdGVETlNJUCI6IjguOC40LjQiLCJEb21lc3RpY0ROU1R5cGUiOiJEb0giLCJEb21lc3RpY0ROU0RvbWFpbiI6Imh0dHBzOi8vY2xvdWRmbGFyZS1kbnMuY29tL2Rucy1xdWVyeSIsIkRvbWVzdGljRE5TSVAiOiIxLjEuMS4xIiwiR2VvaXB1cmwiOiJodHRwczovL2dpdGh1Yi5jb20vTG95YWxzb2xkaWVyL3YycmF5LXJ1bGVzLWRhdC9yZWxlYXNlcy9sYXRlc3QvZG93bmxvYWQvZ2VvaXAuZGF0IiwiR2Vvc2l0ZXVybCI6Imh0dHBzOi8vZ2l0aHViLmNvbS9Mb3lhbHNvbGRpZXIvdjJyYXktcnVsZXMtZGF0L3JlbGVhc2VzL2xhdGVzdC9kb3dubG9hZC9nZW9zaXRlLmRhdCIsIkxhc3RVcGRhdGVkIjoiMTc3NTIwNjEwOCIsIkRuc0hvc3RzIjp7fSwiRGlyZWN0U2l0ZXMiOlsiZ2Vvc2l0ZTpjYXRlZ29yeS1ydSIsImdlb3NpdGU6cHJpdmF0ZSJdLCJEaXJlY3RJcCI6WyJnZW9pcDpwcml2YXRlIl0sIlByb3h5U2l0ZXMiOltdLCJQcm94eUlwIjpbXSwiQmxvY2tTaXRlcyI6WyJnZW9zaXRlOmNhdGVnb3J5LWFkcyIsImdlb3NpdGU6d2luLXNweSJdLCJCbG9ja0lwIjpbXSwiRG9tYWluU3RyYXRlZ3kiOiJJUElmTm9uTWF0Y2giLCJGYWtlRE5TIjoiZmFsc2UiLCJVc2VDaHVua0ZpbGVzIjoiZmFsc2UifQ";
        
        add_header routing-enable 0;
    }

    location ~ /\.ht {
        deny all;
    }
}

server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

systemctl restart nginx
echo -e "${GRN}✅ Конфигурация nginx обновлена.${NC}"

# Определяем директорию скрипта
SCRIPT_DIR=/usr/local/etc/xray

# Генерируем переменные
xray_uuid_vrv=$(xray uuid)

key_output=$(xray x25519)
xray_privateKey_vrv=$(echo "$key_output" | awk -F': ' '/PrivateKey/ {print $2}')
xray_publicKey_vrv=$(echo "$key_output" | awk -F': ' '/Password/ {print $2}')

key_mldsa65=$(xray mldsa65)
seed_mldsa65=$(echo "$key_mldsa65" | awk -F': ' '/Seed/ {print $2}')
verify_mldsa65=$(echo "$key_mldsa65" | awk -F': ' '/Verify/ {print $2}')

xray_shortIds_vrv=$(openssl rand -hex 8)

xray_sspasw_vrv=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)

ipserv=$(hostname -I | awk '{print $1}')

# Экспортируем переменные для envsubst
export xray_uuid_vrv xray_privateKey_vrv xray_publicKey_vrv xray_shortIds_vrv xray_sspasw_vrv DOMAIN path_subpage WEB_PATH TYPE FP SNI SPX PBK SECURITY FLOW SID uuidVL addressVL portVL

# Создаем JSON конфигурацию сервера
cat << 'EOF' | envsubst > "$SCRIPT_DIR/config.json"
{
  "log": {
    "dnsLog": false,
    "loglevel": "none"
  },
  "dns": {
    "servers": [
      "https+local://8.8.4.4/dns-query",
      "https+local://8.8.8.8/dns-query",
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "VtcpRself",
      "port": 443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "flow": "xtls-rprx-vision",
            "id": "${xray_uuid_vrv}"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "xver": 1,
          "target": "/dev/shm/nginx.sock",
          "spiderX": "/",
          "shortIds": [
            "${xray_shortIds_vrv}"
          ],
          "privateKey": "${xray_privateKey_vrv}",
          "serverNames": [
            "$DOMAIN"
          ],
          "limitFallbackUpload": {
            "afterBytes": 0,
            "bytesPerSec": 65536,
            "burstBytesPerSec": 0
          },
          "limitFallbackDownload": {
            "afterBytes": 5242880,
            "bytesPerSec": 262144,
            "burstBytesPerSec": 2097152
          }
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "port": ${portVL},
            "users": [
              {
                "id": "$uuidVL",
                "flow": "$FLOW",
                "level": 0,
                "encryption": "none"
              }
            ],
            "address": "$addressVL"
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "$SECURITY",
        "realitySettings": {
          "show": false,
          "fingerprint": "$FP",
          "serverName": "$SNI",
          "password": "$PBK",
          "shortId": "$SID",
          "mldsa65Verify": "",
          "spiderX": "$SPX"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "ForceIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "geosite:category-ads",
          "geosite:win-spy",
          "geosite:private"
        ],
        "outboundTag": "block"
      },
      {
        "domain": [
          "testipv6.net",
          "geosite:apple",
          "geosite:apple-pki",
          "geosite:huawei",
          "geosite:xiaomi",
          "geosite:category-android-app-download",
          "geosite:f-droid",
          "geosite:yandex",
          "geosite:vk",
          "geosite:microsoft",
          "geosite:win-update",
          "geosite:win-extra",
          "geosite:google-play",
          "geosite:steam",
          "geosite:category-ru"
        ],
        "outboundTag": "direct"
      },
      {
        "inboundTag": [
          "VtcpRself"
        ],
        "outboundTag": "proxy"
      }
    ],
    "domainStrategy": "IPIfNonMatch"
  }
}

EOF

# Создаем JSON конфигурацию клиента
cat << 'EOF' | envsubst > "$WEB_PATH/$path_subpage.json"
[
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "https://8.8.4.4/dns-query",
      "https://8.8.8.8/dns-query",
      "https://1.1.1.1/dns-query"
    ],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "domain": [
          "geosite:category-ads",
          "geosite:win-spy"
        ],
        "outboundTag": "block"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "direct"
      },
      {
        "domain": [
          "habr.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "domain": [
          "geosite:private",
          "geosite:apple",
          "geosite:apple-pki",
          "geosite:huawei",
          "geosite:xiaomi",
          "geosite:category-android-app-download",
          "geosite:f-droid",
          "geosite:yandex",
          "geosite:vk",
          "geosite:microsoft",
          "geosite:win-update",
          "geosite:win-extra",
          "geosite:google-play",
          "geosite:steam",
          "geosite:category-ru"
        ],
        "outboundTag": "direct"
      },
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": 10808,
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "socks-sb",
      "protocol": "socks",
      "listen": "127.0.0.1",
      "port": 2080,
      "settings": {
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    },
    {
      "tag": "http-in",
      "protocol": "http",
      "listen": "127.0.0.1",
      "port": 10809,
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$DOMAIN",
            "port": 443,
            "users": [
              {
                "id": "${xray_uuid_vrv}",
                "flow": "xtls-rprx-vision",
                "encryption": "none",
                "level": 0
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "$DOMAIN",
          "password": "${xray_publicKey_vrv}",
          "shortId": "${xray_shortIds_vrv}",
          "mldsa65Verify": "",
          "spiderX": "/"
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "remarks": "🇪🇺 Bridge RU-EU vlsRAWrtyVISION"
}
]
EOF

# Перезапуск Xray
echo -e "${YEL}Перезапуск Xray...${NC}"
systemctl restart xray
echo -e "${GRN}Готово!${NC}\n"

# Формирование ссылок
subPageLink="https://$DOMAIN/$path_subpage.json"

# Формирование ссылок
link1="vless://${xray_uuid_vrv}@$DOMAIN:443?security=reality&sni=$DOMAIN&fp=chrome&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&type=tcp&flow=xtls-rprx-vision&encryption=none&spx=%2F#vlessAXbrEU"

# --- ФИНАЛЬНАЯ ПРОВЕРКА ---
echo -e "\n${YEL}=== Финальная проверка статусов ===${NC}"

# Проверка Nginx
if systemctl is-active --quiet nginx; then
    echo -e "Nginx: ${GRN}RUNNING${NC}"
else
    echo -e "Nginx: ${RED}STOPPED/ERROR${NC}"
fi

# Проверка XRAY
if systemctl is-active --quiet xray; then
    echo -e "XRAY: ${GRN}RUNNING${NC}"
else
    echo -e "XRAY: ${RED}STOPPED/ERROR${NC}"
fi

# Проверка, что файлы подписки созданы
if [ -f "$WEB_PATH/$path_subpage.json" ]; then
    echo -e "Subscription JSON: ${GRN}OK${NC}"
else
    echo -e "Subscription JSON: ${RED}MISSING${NC}"
fi

if [ -f "$WEB_PATH/$path_subpage.html" ]; then
    echo -e "Subscription HTML: ${GRN}OK${NC}"
else
    echo -e "Subscription HTML: ${RED}MISSING${NC}"
fi

echo -e "\n"
echo -e "
Скопируйте подписку в специализированное приложение:
- iOS: Happ или v2RayTun или v2rayN
- Android: Happ или v2RayTun или v2rayNG
- Windows: конфиги winLoadXRAY или v2rayN или ядро Xray
    для vless Happ(alpha) или v2RayTun или Throne


Ваша страничка подписки:
${GRN}$subPageLink${NC}

Ваш конфиг для роутера:
$link1

Открыт локальный socks5 на порту 10808, 1080, 2080 и http на 10809.
"