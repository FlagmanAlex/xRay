#!/bin/bash

# ============================================
# autoXRAY с WARP (оптимизированный для агрессивного DPI)
# Версия: 2.0 с поддержкой wireproxy
# ============================================

# Цвета для вывода
GRN='\033[1;32m'
RED='\033[1;31m'
YEL='\033[1;33m'
BLU='\033[1;34m'
NC='\033[0m' # No Color

# Проверка root прав
[[ $EUID -eq 0 ]] || { echo -e "${RED}❌ скрипту нужны root права ${NC}"; exit 1; }

DOMAIN=$1

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ Ошибка: домен не задан.${NC}"
    echo -e "${YEL}Использование: $0 your.domain.com${NC}"
    exit 1
fi

echo -e "${BLU}========================================${NC}"
echo -e "${BLU}  autoXRAY с WARP (оптимизированный)${NC}"
echo -e "${BLU}  Домен: $DOMAIN${NC}"
echo -e "${BLU}========================================${NC}"

# ============================================
# 1. УСТАНОВКА ПАКЕТОВ
# ============================================
echo -e "${YEL}📦 Обновление и установка необходимых пакетов...${NC}"
apt-get update && apt-get install curl jq dnsutils openssl nginx certbot wget tar lsof -y
systemctl enable --now nginx

# ============================================
# 2. ПРОВЕРКА DNS
# ============================================
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

# ============================================
# 3. ВОПРОСЫ ПОЛЬЗОВАТЕЛЮ
# ============================================
echo -e "\n${YEL}⚙️  Настройка компонентов:${NC}"

read -p "$(echo -e "\n${YEL}Устанавливать MTProxy для Telegram? (y/n, по умолчанию y): ${NC}")" choice_mtp
choice_mtp=${choice_mtp:-y}
if [[ "$choice_mtp" =~ ^[Yy]$ ]]; then
    TARGET_MTP="127.0.0.1:500"
    INSTALL_MTP=true
else
    TARGET_MTP="/dev/shm/nginx.sock"
    INSTALL_MTP=false
fi

echo -e "\n${YEL}Выберите TLS fingerprint для маскировки трафика:${NC}"
echo "1) chrome    3) safari   5) android   7) 360"
echo "2) firefox   4) ios      6) edge      8) qq"
read -p "Введите номер [1-8] (по умолчанию 2 - firefox): " fp_choice

case $fp_choice in
    1) fpBro="chrome" ;;
    2) fpBro="firefox" ;;
    3) fpBro="safari" ;;
    4) fpBro="ios" ;;
    5) fpBro="android" ;;
    6) fpBro="edge" ;;
    7) fpBro="360" ;;
    8) fpBro="qq" ;;
    *) fpBro="firefox" ;;
esac

# ============================================
# 4. ВКЛЮЧЕНИЕ BBR И НАСТРОЙКА ЛИМИТОВ
# ============================================
echo -e "${YEL}🚀 Оптимизация системы...${NC}"

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

# ============================================
# 5. УСТАНОВКА WARP (wireproxy)
# ============================================
echo -e "${YEL}🌐 Установка WARP через wireproxy...${NC}"

# Установка wireproxy
wget -O /usr/local/bin/wireproxy https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_linux_amd64
chmod +x /usr/local/bin/wireproxy

# Создание конфига wireproxy
cat > /etc/wireguard/proxy.conf << 'EOF'
[Socks5]
BindAddress = 127.0.0.1:40000

[Interface]
Address = 172.16.0.2/32, 2606:4700:110:8495:d7b9:fe:c14d:acc3/128
MTU = 1420
PrivateKey = f5mVrzYRFhRSjjaFKFNSdLdVpKPYdwuPZwkO01NFqI4=
DNS = 1.1.1.1,8.8.8.8

[Config]
MTU = 1420
TCPKeepAlive = 30
BufferSize = 65535
HandshakeTimeout = 60
ConnectionTimeout = 120
ResolveStrategy = ipv4

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
EOF

# Создание systemd-сервиса для wireproxy
cat > /etc/systemd/system/wireproxy.service << 'EOF'
[Unit]
Description=WireProxy (WARP Socks5)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireproxy -c /etc/wireguard/proxy.conf
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wireproxy
systemctl start wireproxy

# Проверка статуса WARP
sleep 2
if ss -tuln | grep -q ":40000 "; then
    echo -e "${GRN}✅ WARP (wireproxy) запущен на порту 40000${NC}"
else
    echo -e "${RED}❌ Ошибка запуска WARP. Проверьте логи: journalctl -u wireproxy${NC}"
fi

TAG_WARP="warp"
INSTALL_WARP=true

# ============================================
# 6. СОЗДАНИЕ САЙТА-МАСКИРОВКИ
# ============================================
WEB_PATH="/var/www/$DOMAIN"
mkdir -p "$WEB_PATH"
bash -c "$(curl -L https://github.com/xVRVx/autoXRAY/raw/refs/heads/main/test/gen_page2.sh)" -- $WEB_PATH

# ============================================
# 7. УСТАНОВКА XRAY
# ============================================
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# ============================================
# 8. ПОЛУЧЕНИЕ SSL СЕРТИФИКАТОВ
# ============================================
if [ -f /etc/nginx/sites-available/default ]; then
    CONFIG_PATH="/etc/nginx/sites-available/default"
    echo -e "${GRN}Обнаружена стандартная сборка nginx.${NC}"
elif [ -f /etc/nginx/conf.d/default.conf ]; then
    CONFIG_PATH="/etc/nginx/conf.d/default.conf"
    echo -e "${YEL}Обнаружена нестандартная сборка nginx.${NC}"
    mkdir -p /var/www/html
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

mkdir -p /var/lib/xray/cert/

certbot certonly --webroot -w /var/www/html \
  -d $DOMAIN \
  -m mail@$DOMAIN \
  --agree-tos --non-interactive \
  --deploy-hook "systemctl reload nginx; cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem /var/lib/xray/cert/fullchain.pem; cp /etc/letsencrypt/live/$DOMAIN/privkey.pem /var/lib/xray/cert/privkey.pem; chmod 744 /var/lib/xray/cert/privkey.pem; chmod 744 /var/lib/xray/cert/fullchain.pem; systemctl restart xray"

RET=$?

if [ $RET -eq 0 ]; then
    echo -e "${GRN}✅ Сертификат https от letsencrypt ПОЛУЧЕН${NC}"
else
    echo -e "${RED}❌ CERTBOT ЗАВЕРШИЛСЯ С ОШИБКОЙ${NC}"
    exit 1
fi

# ============================================
# 9. НАСТРОЙКА NGINX
# ============================================
path_xhttp=$(openssl rand -base64 15 | tr -dc 'a-z0-9' | head -c 6)
path_subpage=$(openssl rand -base64 15 | tr -dc 'A-Za-z0-9' | head -c 20)

bash -c "cat > $CONFIG_PATH" <<EOF
server {
    server_name $DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl http2 proxy_protocol;
    listen unix:/dev/shm/nginxTLS.sock proxy_protocol;
    listen unix:/dev/shm/nginx_h2.sock http2 proxy_protocol;
    set_real_ip_from unix:;
    real_ip_header proxy_protocol;
    
    root /var/www/$DOMAIN;
    index index.php index.html;
    
    grpc_read_timeout 1h;
    grpc_send_timeout 1h;
    grpc_set_header X-Real-IP \$remote_addr;
    
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
    
    location /${path_xhttp} {
        proxy_pass http://127.0.0.1:8400;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }
    
    location /${path_xhttp}11 {
        if (\$request_method != "POST") {
            return 404;
        }
        client_body_buffer_size 1m;
        client_body_timeout 1h;
        client_max_body_size 0;
        grpc_pass grpc://127.0.0.1:8411;
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

# ============================================
# 10. ГЕНЕРАЦИЯ КЛЮЧЕЙ XRAY
# ============================================
SCRIPT_DIR=/usr/local/etc/xray

xray_uuid_vrv=$(xray uuid)
key_output=$(xray x25519)
xray_privateKey_vrv=$(echo "$key_output" | awk -F': ' '/PrivateKey/ {print $2}')
xray_publicKey_vrv=$(echo "$key_output" | awk -F': ' '/Password/ {print $2}')
xray_shortIds_vrv=$(openssl rand -hex 8)
xray_sspasw_vrv=$(openssl rand -base64 32)
socksUser=$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 6)
socksPasw=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 16)

# ============================================
# 11. ЭКСПОРТ ПЕРЕМЕННЫХ
# ============================================
export xray_uuid_vrv xray_privateKey_vrv xray_publicKey_vrv xray_shortIds_vrv
export xray_sspasw_vrv DOMAIN path_subpage path_xhttp WEB_PATH socksUser socksPasw
export TARGET_MTP TAG_WARP fpBro

# ============================================
# 12. СОЗДАНИЕ КОНФИГА XRAY (с WARP)
# ============================================
cat << 'EOF' | envsubst > "$SCRIPT_DIR/config.json"
{
  "log": {
    "dnsLog": false,
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
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
      "tag": "vsRAWrtyVISION",
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
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "3333",
            "xver": 2
          }
        ]
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
        "sockopt": {
          "acceptProxyProtocol": false,
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 30
        },
        "realitySettings": {
          "show": false,
          "xver": 2,
          "target": "${TARGET_MTP}",
          "spiderX": "/",
          "shortIds": [
            "${xray_shortIds_vrv}"
          ],
          "privateKey": "${xray_privateKey_vrv}",
          "serverNames": [
            "$DOMAIN"
          ]
        }
      }
    },
    {
      "tag": "vsXHTTPrty",
      "port": 3333,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
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
        "network": "xhttp",
        "xhttpSettings": {
          "mode": "stream-one",
          "path": "/${path_xhttp}"
        },
        "security": "none",
        "sockopt": {
          "acceptProxyProtocol": true
        }
      }
    },
    {
      "tag": "vsRAWtlsVISION",
      "port": 8443,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "flow": "xtls-rprx-vision",
            "id": "${xray_uuid_vrv}"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "path": "/${path_xhttp}22",
            "dest": "@vless-ws",
            "xver": 2
          },
          {
            "path": "/ssws",
            "dest": "4001"
          },
          {
            "alpn": "h2",
            "dest": "/dev/shm/nginx_h2.sock",
            "xver": 2
          },
          {
            "dest": "/dev/shm/nginxTLS.sock",
            "xver": 2
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "tls",
        "sockopt": {
          "tcpFastOpen": true,
          "tcpNoDelay": true,
          "tcpKeepAliveInterval": 30
        },
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/var/lib/xray/cert/fullchain.pem",
              "keyFile": "/var/lib/xray/cert/privkey.pem"
            }
          ],
          "minVersion": "1.2",
          "cipherSuites": "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256:TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384:TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256:TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256",
          "alpn": [
            "h2", "http/1.1"
          ]
        }
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
      "tag": "vsXHTTPtls",
      "port": 8400,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${xray_uuid_vrv}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/${path_xhttp}"
        },
        "security": "none",
        "sockopt": {
          "acceptProxyProtocol": false
        }
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
      "tag": "vsGRPCtls",
      "port": 8411,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${xray_uuid_vrv}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "${path_xhttp}11"
        },
        "security": "none"
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
      "listen": "@vless-ws",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${xray_uuid_vrv}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "acceptProxyProtocol": true,
          "path": "/${path_xhttp}22"
        },
        "security": "none"
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
      "tag": "socks5",
      "port": 10443,
      "listen": "127.0.0.1",
      "protocol": "mixed",
      "settings": {
        "ip": "127.0.0.1",
        "udp": true,
        "auth": "password",
        "accounts": [
          {
            "user": "${socksUser}",
            "pass": "${socksPasw}"
          }
        ]
      }
    },
    {
      "tag": "Hysteria2",
      "listen": "0.0.0.0",
      "port": 8080,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${xray_shortIds_vrv}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$DOMAIN",
          "alpn": [
            "h3"
          ],
          "certificates": [
            {
              "usage": "encipherment",
              "certificateFile": "/var/lib/xray/cert/fullchain.pem",
              "keyFile": "/var/lib/xray/cert/privkey.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "auth": "${xray_shortIds_vrv}"
        },
        "finalmask": {
          "quicParams": {
            "congestion": "brutal",
            "brutalUp": "100 mbps",
            "brutalDown": "100 mbps"
          }
        }
      }
    }
  ],
  "outbounds": [
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
    },
    {
      "tag": "warp",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
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
        "port": "25",
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
        "outboundTag": "warp",
        "domain": [
          "ifconfig.me",
          "checkip.amazonaws.com",
          "pify.org",
          "2ip.io",
          "habr.com",
          "geosite:category-ip-geo-detect",
          "geosite:google-gemini",
          "geosite:canva",
          "geosite:openai",
          "geosite:whatsapp"
        ]
      }
    ],
    "domainStrategy": "IPIfNonMatch"
  }
}
EOF

# ============================================
# 13. ГЕНЕРАЦИЯ КЛИЕНТСКИХ КОНФИГОВ
# ============================================
print_config() {
  local PROXY_OUTBOUND="$1"
  local REMARK="$2"

  cat << TPL
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
          "habr.com", "apkmirror.com"
        ],
        "outboundTag": "proxy"
      },
      {
        "domain": [
          "geosite:private",
          "ifconfig.me",
          "checkip.amazonaws.com",
          "pify.org",
          "geosite:category-ip-geo-detect",
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
      $PROXY_OUTBOUND,
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "remarks": "$REMARK"
}
TPL
}

# --- Config 1 ---
OUT_REALITY_VISION='{
  "mux": { "concurrency": -1, "enabled": false },
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "flow": "xtls-rprx-vision", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "show": false, "fingerprint": "$fpBro", "serverName": "$DOMAIN",
      "password": "${xray_publicKey_vrv}", "shortId": "${xray_shortIds_vrv}", "spiderX": "/"
    }
  }
}'

# --- Config 2 ---
OUT_REALITY_XHTTP='{
  "mux": { "concurrency": -1, "enabled": false },
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {
      "mode": "stream-one",
      "path": "/${path_xhttp}",
      "extra": {
        "noGRPCHeader": false,
        "scMaxEachPostBytes": 1500000,
        "scMinPostsIntervalMs": 20,
        "scStreamUpServerSecs": "60-240",
        "xPaddingBytes": "400-800",
        "xmux": {
          "cMaxReuseTimes": "1000-3000",
          "hKeepAlivePeriod": 0,
          "hMaxRequestTimes": "400-700",
          "hMaxReusableSecs": "1200-1800",
          "maxConcurrency": "3-5",
          "maxConnections": 0
        }
      }
    },
    "realitySettings": {
      "show": false, "fingerprint": "$fpBro", "serverName": "$DOMAIN",
      "password": "${xray_publicKey_vrv}", "shortId": "${xray_shortIds_vrv}", "spiderX": "/"
    }
  }
}'

# --- Config 3 ---
OUT_VISION='{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 8443,
      "users": [{ "id": "${xray_uuid_vrv}", "flow": "xtls-rprx-vision", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "raw",
    "security": "tls",
    "tlsSettings": {
      "serverName": "$DOMAIN",
      "fingerprint": "$fpBro"
    }
  }
}'

# --- Config 4 ---
OUT_XHTTP='{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 8443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": {
      "extra": {
        "headers": {
        },
        "noGRPCHeader": false,
        "scMaxEachPostBytes": 1500000,
        "scMinPostsIntervalMs": 20,
        "scStreamUpServerSecs": "60-240",
        "xPaddingBytes": "400-800",
        "xmux": {
          "cMaxReuseTimes": "1000-3000",
          "hKeepAlivePeriod": 0,
          "hMaxRequestTimes": "400-700",
          "hMaxReusableSecs": "1200-1800",
          "maxConcurrency": "3-5",
          "maxConnections": 0
        }
      },
      "mode": "auto", "path": "/${path_xhttp}" },
    "security": "tls",
    "tlsSettings": { "serverName": "$DOMAIN", "fingerprint": "$fpBro" }
  }
}'

# --- Config 5 ---
OUT_GRPC='{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 8443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "grpc",
    "grpcSettings": { "serviceName": "${path_xhttp}11", "multiMode": false },
    "security": "tls",
    "tlsSettings": { "serverName": "$DOMAIN", "alpn": ["h2"], "fingerprint": "$fpBro" }
  }
}'

# --- Config 6 ---
OUT_WS='{
  "tag": "proxy",
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$DOMAIN",
      "port": 8443,
      "users": [{ "id": "${xray_uuid_vrv}", "encryption": "none" }]
    }]
  },
  "streamSettings": {
    "network": "ws",
    "wsSettings": { "path": "/${path_xhttp}22" },
    "security": "tls",
    "tlsSettings": { "serverName": "$DOMAIN", "fingerprint": "$fpBro" }
  }
}'

# --- Config 7 ---
HYSTERIA2='{
  "tag": "proxy",
  "protocol": "hysteria",
  "settings": {
    "address": "$DOMAIN",
    "port": 8080,
    "version": 2
  },
  "streamSettings": {
    "network": "hysteria",
    "security": "tls",
    "tlsSettings": {
      "serverName": "$DOMAIN",
      "alpn": [
        "h3"
      ]
    },
    "fingerprint": "$fpBro",
    "hysteriaSettings": {
      "version": 2,
      "auth": "${xray_shortIds_vrv}"
    },
    "finalmask": {
      "quicParams": {
        "congestion": "brutal",
        "brutalUp": "100 mbps",
        "brutalDown": "100 mbps"
      }
    }
  }
}'

# Генерация JSON с конфигами
(
  echo "["
  print_config "$OUT_REALITY_XHTTP"  "🇪🇺 VLESS XHTTP REALITY EXTRA"
  echo ","
  print_config "$OUT_REALITY_VISION" "🇪🇺 VLESS RAW REALITY VISION"
  echo ","
  print_config "$HYSTERIA2" "🇪🇺 HYSTERIA2"
  echo ","
  print_config "$OUT_VISION"    "🇪🇺 VLESS RAW TLS VISION"
  echo ","
  print_config "$OUT_XHTTP"     "🇪🇺 VLESS XHTTP TLS EXTRA"
  echo ","
  print_config "$OUT_GRPC"      "🇪🇺 VLESS gRPC TLS"
  echo ","
  print_config "$OUT_WS"        "🇪🇺 VLESS WS TLS"
  echo "]"
) | envsubst > "$WEB_PATH/$path_subpage.json"

# ============================================
# 14. ЗАПУСК XRAY
# ============================================
systemctl restart xray
echo -e "${GRN}✅ Xray перезапущен${NC}"

# ============================================
# 15. МTPROTO (опционально)
# ============================================
if [ "$INSTALL_MTP" = true ]; then
    echo -e "${YEL}📱 Устанавливаем MTProto FakeTLS для Telegram${NC}"
    source <(curl -sL https://github.com/xVRVx/autoXRAY/raw/refs/heads/main/test/telemt-test.sh)
else
    echo -e "${YEL}⏭️  Установка MTProto пропущена${NC}"
    MTProto=""
fi

# ============================================
# 16. ГЕНЕРАЦИЯ HTML СТРАНИЦЫ
# ============================================
subPageLink="https://$DOMAIN/$path_subpage.json"
configListLink="https://$DOMAIN/$path_subpage.html"

hy2="hy2://${xray_shortIds_vrv}@$DOMAIN:8080/?sni=$DOMAIN&alpn=h3"
linkRTY1="vless://${xray_uuid_vrv}@$DOMAIN:443?security=reality&type=tcp&headerType=&path=&host=&flow=xtls-rprx-vision&sni=$DOMAIN&fp=$fpBro&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&spx=%2F#vlessRAWrealityVISION-autoXRAY"
linkRTY2="vless://${xray_uuid_vrv}@$DOMAIN:443?security=reality&type=xhttp&headerType=&path=%2F$path_xhttp&host=&mode=stream-one&extra=%7B%22xmux%22%3A%7B%22cMaxReuseTimes%22%3A%221000-3000%22%2C%22maxConcurrency%22%3A%223-5%22%2C%22maxConnections%22%3A0%2C%22hKeepAlivePeriod%22%3A0%2C%22hMaxRequestTimes%22%3A%22400-700%22%2C%22hMaxReusableSecs%22%3A%221200-1800%22%7D%2C%22headers%22%3A%7B%7D%2C%22noGRPCHeader%22%3Afalse%2C%22xPaddingBytes%22%3A%22400-800%22%2C%22scMaxEachPostBytes%22%3A1500000%2C%22scMinPostsIntervalMs%22%3A20%2C%22scStreamUpServerSecs%22%3A%2260-240%22%7D&sni=$DOMAIN&fp=$fpBro&pbk=${xray_publicKey_vrv}&sid=${xray_shortIds_vrv}&spx=%2F#vlessXHTTPrealityEXTRA-autoXRAY"
linkTLS1="vless://${xray_uuid_vrv}@$DOMAIN:8443?security=tls&type=tcp&headerType=&path=&host=&flow=xtls-rprx-vision&sni=$DOMAIN&fp=$fpBro&spx=%2F#vlessRAWtlsVision-autoXRAY"
linkTLS2="vless://${xray_uuid_vrv}@$DOMAIN:8443?security=tls&type=xhttp&headerType=&path=%2F${path_xhttp}&host=&mode=auto&extra=%7B%22xmux%22%3A%7B%22cMaxReuseTimes%22%3A%221000-3000%22%2C%22maxConcurrency%22%3A%223-5%22%2C%22maxConnections%22%3A0%2C%22hKeepAlivePeriod%22%3A0%2C%22hMaxRequestTimes%22%3A%22400-700%22%2C%22hMaxReusableSecs%22%3A%221200-1800%22%7D%2C%22headers%22%3A%7B%7D%2C%22noGRPCHeader%22%3Afalse%2C%22xPaddingBytes%22%3A%22400-800%22%2C%22scMaxEachPostBytes%22%3A1500000%2C%22scMinPostsIntervalMs%22%3A20%2C%22scStreamUpServerSecs%22%3A%2260-240%22%7D&sni=$DOMAIN&fp=$fpBro&spx=%2F#vlessXHTTPtls-autoXRAY"
linkTLS3="vless://${xray_uuid_vrv}@$DOMAIN:8443?security=tls&type=ws&headerType=&path=%2F${path_xhttp}22&host=&sni=$DOMAIN&fp=$fpBro&spx=%2F#vlessWStls-autoXRAY"
linkTLS4="vless://${xray_uuid_vrv}@$DOMAIN:8443?security=tls&type=grpc&headerType=&serviceName=${path_xhttp}11&host=&sni=$DOMAIN&fp=$fpBro&spx=%2F#vlessGRPCtls-autoXRAY"

CONFIGS_ARRAY=(
    "VLESS XHTTP REALITY EXTRA (для моста)|$linkRTY2"
    "VLESS RAW REALITY VISION|$linkRTY1"
    "HYSTERIA2|$hy2"
    "VLESS RAW TLS VISION|$linkTLS1"
    "VLESS XHTTP TLS EXTRA|$linkTLS2"
    "VLESS WS TLS|$linkTLS3"
    "VLESS GRPC TLS|$linkTLS4"
)

ALL_LINKS_TEXT=""
for item in "${CONFIGS_ARRAY[@]}"; do
    title="${item%%|*}"
    link="${item#*|}"
    if [ -z "$ALL_LINKS_TEXT" ]; then ALL_LINKS_TEXT="$link"; else ALL_LINKS_TEXT="$ALL_LINKS_TEXT<br>$link"; fi
done

# Создание HTML страницы
cat > "$WEB_PATH/$path_subpage.html" <<'EOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<meta name="robots" content="noindex,nofollow">
<title>autoXRAY configs with WARP</title>
<link rel="icon" type="image/svg+xml" href='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjMDBCRkZGIiBzdHJva2Utd2lkdGg9IjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTIxIDJsLTIgMm0tNy42MSA3LjYxYTUuNSA1LjUgMCAxIDEtNy43NzggNy43NzggNS41IDUuNSAwIDAgMSA3Ljc3Ny03Ljc3N3ptMCAwTDE1LjUgNy41bTAgMGwzIDNMMjIgN2wtMy0zbS0zLjUgMy41TDE5IDQiLz48L3N2Zz4='>
<script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
<style>
body{font-family:monospace;background:#121212;color:#e0e0e0;padding:10px;max-width:900px;margin:0 auto}
h2{color:#c3e88d;border-top:2px solid #333;padding-top:20px;margin:15px 0 10px;font-size:18px}
.config-row{background:#1e1e1e;border:1px solid #333;border-radius:6px;padding:5px;display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-bottom:8px}
.config-label{background:#2c2c2c;color:#82aaff;padding:6px 10px;border-radius:4px;font-weight:700;font-size:13px;white-space:nowrap;min-width:140px;text-align:center}
.config-code{flex:1;white-space:nowrap;overflow-x:auto;padding:8px;background:#121212;border-radius:4px;color:#c3e88d;font-size:12px;scrollbar-width:none}
.config-code::-webkit-scrollbar{display:none}
.btn-action{border:1px solid #555;padding:6px 12px;border-radius:4px;cursor:pointer;font-weight:700;font-size:12px;transition:all .2s;height:32px;display:flex;align-items:center;justify-content:center}
.copy-btn{background:#333;color:#e0e0e0;min-width:60px}
.copy-btn:hover{background:#c3e88d;color:#121212;border-color:#c3e88d}
.qr-btn{background:#333;color:#82aaff;border-color:#82aaff;min-width:40px}
.qr-btn:hover{background:#82aaff;color:#121212}
.btn-group{display:flex;gap:10px;margin:10px 0 20px}
.btn{flex:1;background:#2c2c2c;color:#c3e88d;border:1px solid #c3e88d;padding:10px;text-align:center;border-radius:6px;text-decoration:none;font-weight:700;font-size:14px}
.btn:hover{background:#c3e88d;color:#121212}
.btn.download{border-color:#82aaff;color:#82aaff}
.btn.download:hover{background:#82aaff;color:#121212}
.btn.tg{border-color:#2AABEE;color:#2AABEE}
.btn.tg:hover{background:#2AABEE;color:#fff}
.modal-overlay{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.85);z-index:999;justify-content:center;align-items:center;backdrop-filter:blur(3px)}
.modal-content{background:#1e1e1e;padding:20px;border-radius:10px;border:1px solid #82aaff;text-align:center}
#qrcode{background:#fff;padding:10px;border-radius:6px;margin-bottom:10px}
.close-modal-btn{background:#c31e1e;color:#fff;border:none;padding:8px 20px;border-radius:4px;cursor:pointer}
.badge-warp{background:#2AABEE;color:#fff;padding:2px 10px;border-radius:12px;font-size:11px;margin-left:8px}
@media(max-width:600px){.config-label{width:100%;margin-bottom:2px}.config-code{min-width:100%;order:3}.btn-action{flex:1;order:2}}
</style>
<script>
function copyText(e,t){navigator.clipboard.writeText(document.getElementById(e).innerText).then(()=>{let o=t.innerText;t.innerText="OK",t.style.cssText="background:#c3e88d;color:#121212",setTimeout(()=>{t.innerText=o,t.style.cssText=""},1500)}).catch(e=>console.error(e))}
function showQR(e){let t=document.getElementById(e).innerText,o=document.getElementById("qrModal"),n=document.getElementById("qrcode");n.innerHTML="",new QRCode(n,{text:t,width:256,height:256,colorDark:"#000000",colorLight:"#ffffff",correctLevel:QRCode.CorrectLevel.L}),o.style.display="flex"}
function closeModal(){document.getElementById("qrModal").style.display="none"}window.onclick=function(e){e.target==document.getElementById("qrModal")&&closeModal()};
</script>
</head><body>
EOF

cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div style="background:#1e2a1e;border:1px solid #c3e88d;border-radius:8px;padding:12px;margin-bottom:20px;text-align:center">
    <span style="color:#c3e88d;font-size:14px;">⚡ WARP включен для OpenAI, WhatsApp и обхода блокировок</span>
</div>

<h2>📂 Ссылка на подписку</h2>
<div class="config-row">
    <div class="config-label">Subscription</div>
    <div class="config-code" id="subLink">$subPageLink</div>
    <button class="btn-action copy-btn" onclick="copyText('subLink', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('subLink')">QR</button>
</div>

<h2>📱 Приложение HAPP</h2>
<div class="btn-group">
    <a href="happ://add/$subPageLink" class="btn">⚡ Add to HAPP</a>
    <a href="https://www.happ.su/main/ru" target="_blank" class="btn download">⬇️ Download App</a>
</div>

<h2>➡️ Конфиги</h2>
EOF

idx=1
for item in "${CONFIGS_ARRAY[@]}"; do
    title="${item%%|*}"
    link="${item#*|}"
    cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div class="config-row">
    <div class="config-label">$title</div>
    <div class="config-code" id="c$idx">$link</div>
    <button class="btn-action copy-btn" onclick="copyText('c$idx', this)">Copy</button>
    <button class="btn-action qr-btn" onclick="showQR('c$idx')">QR</button>
</div>
EOF
    ((idx++))
done

if [ "$INSTALL_MTP" = true ]; then
    cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<div class="config-row">
    <div class="config-label">MTProtoFakeTLS (TG)</div>
    <div class="config-code" id="mtproto">${MTProto}</div>
    <button class="btn-action copy-btn" onclick="copyText('mtproto', this)">Copy</button>
    <a href="${MTProto}" target="_blank" class="btn-action qr-btn" style="text-decoration:none">✈️ Add to TG</a>
</div>
EOF
fi

cat >> "$WEB_PATH/$path_subpage.html" <<EOF
<h2>💠 Все конфиги вместе</h2>
<div class="config-row">
    <div class="config-code" id="cAll" style="max-height:60px;white-space:pre-wrap;word-break:break-all">$ALL_LINKS_TEXT</div>
    <button class="btn-action copy-btn" onclick="copyText('cAll', this)">Copy ALL</button>
    <button class="btn-action qr-btn" onclick="showQR('cAll')">QR</button>
</div>

<div style="margin:40px auto 20px;text-align:center;">
    <span style="color:#555;">✅ WARP оптимизирован для работы с большими файлами</span>
</div>

<div id="qrModal" class="modal-overlay"><div class="modal-content"><div id="qrcode"></div><button class="close-modal-btn" onclick="closeModal()">Close</button></div></div>
</body></html>
EOF

# ============================================
# 17. ФИНАЛЬНАЯ ПРОВЕРКА
# ============================================
echo -e "\n${YEL}=== Финальная проверка статусов ===${NC}"

if ss -tuln | grep -q ":40000 "; then
    echo -e "WARP (wireproxy): ${GRN}LISTENING${NC}"
else
    echo -e "WARP (wireproxy): ${RED}NOT LISTENING${NC}"
fi

if systemctl is-active --quiet nginx; then
    echo -e "Nginx: ${GRN}RUNNING${NC}"
else
    echo -e "Nginx: ${RED}STOPPED/ERROR${NC}"
fi

if systemctl is-active --quiet xray; then
    echo -e "XRAY: ${GRN}RUNNING${NC}"
else
    echo -e "XRAY: ${RED}STOPPED/ERROR${NC}"
fi

echo -e "\n${YEL}========================================${NC}"
echo -e "${GRN}✅ Установка завершена!${NC}"
echo -e "${YEL}========================================${NC}"
echo -e "📋 Ваша страница с конфигами: ${GRN}$configListLink${NC}"
echo -e "📋 Подписка: ${GRN}$subPageLink${NC}"
echo -e "${YEL}========================================${NC}"
echo -e "${YEL}WARP активен для:${NC}"
echo -e "  • OpenAI (chat.openai.com)"
echo -e "  • WhatsApp"
echo -e "  • Google Gemini"
echo -e "  • Habr.com"
echo -e "  • Проверка IP (ifconfig.me, 2ip.io)"
echo -e "${YEL}========================================${NC}"