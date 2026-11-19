# Runbook: этапы 0–5 и резерв

Плейсхолдеры: `<IP>` — публичный IPv4 сервера, `<user>` — непривилегированный
пользователь, `<key>` — имя SSH-ключа (например `hetzner-vpn`). Подставлять с человеком,
в прогресс записывать имена, а не секреты.

---

## Определить состояние сервера

Если сервер уже есть — попросить выполнить и показать вывод:

```bash
systemd-detect-virt; lsb_release -ds; uname -r; free -h | head -2
sudo sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|allowusers)'
sudo ufw status verbose
systemctl is-active fail2ban unattended-upgrades
ip -6 addr show scope global
modinfo amneziawg 2>/dev/null | grep -E '^(version|filename)'; dkms status 2>/dev/null
ls /etc/amnezia/amneziawg/ 2>/dev/null
systemctl is-enabled awg-quick@awg0 2>/dev/null; sudo awg show 2>/dev/null | head -20
```

По выводу понять, какой этап закрыт, и продолжить с первого незакрытого. `dkms status`
может показывать модуль как `1.0.0` — это метка пакета; реальная версия в `modinfo`.

---

## Этап 0. Завести и укрепить VPS

Время: 1–1,5 часа плюс возможная верификация аккаунта. Ничего VPN-специфичного здесь нет.

### 0.1 Аккаунт

- Регистрация у хостера. Hetzner может запросить документ для верификации — до неё
  проекты не создаются; начать заранее.
- **2FA на аккаунте сразу**: через аккаунт доступны консоль, снапшоты и пересоздание
  машины — это более ценная цель, чем сам сервер.
- Отдельный проект `vpn`, ни с чем не смешивать. Сайты, боты и прочее — на другом
  VPS: блокировка IP, жалобы или взлом веб-приложения не должны задевать VPN.
- При выборе тарифа смотреть на **включённый трафик**, не на CPU.

### 0.2 SSH-ключ — до создания сервера

На компьютере человека:

```bash
ssh-keygen -t ed25519 -a 100 -C "hetzner-vpn" -f ~/.ssh/<key>
```

С парольной фразой. Публичную часть (`~/.ssh/<key>.pub`) — в панель хостера
(Hetzner: Security → SSH Keys) **до** создания сервера, тогда root-пароль на почту не
придёт вовсе.

### 0.3 Создание сервера

- Образ Ubuntu 24.04, x86, 2 ГБ RAM, локация по таблице в SKILL.md.
- SSH-ключ выбран. IPv4 — да. **Публичный IPv6 — снять.**
- Облачный фаервол (Hetzner Cloud Firewall, назвать `vpn-fw`) — создать и привесить
  сразу: inbound только **TCP 22**. UDP 443 добавится на Этапе 1.

Записать в `~/.ssh/config`:

```
Host vpn
    HostName <IP>
    User root
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes
```

`User root` — временно, до 0.5. Если терминал экзотический (Ghostty, kitty) и на
сервере ломается `clear`/`htop` — добавить `SetEnv TERM=xterm-256color`.

### 0.4 Первый вход и база

```bash
ssh vpn
hostnamectl set-hostname vpn
timedatectl set-timezone Europe/Minsk        # свою зону
apt update && apt full-upgrade -y
apt install -y linux-headers-generic         # иначе после обновления ядра DKMS не соберёт модуль
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
reboot
```

### 0.5 Пользователь

```bash
adduser --gecos "" <user>                    # пароль нужен для sudo и веб-консоли — в менеджер паролей
usermod -aG sudo <user>
rsync --archive --chown=<user>:<user> ~/.ssh /home/<user>/
```

**Второй терминал:** `ssh -i ~/.ssh/<key> <user>@<IP>`, затем `sudo -v`. Только после
успеха — `User <user>` в `~/.ssh/config`. Root-сессию держать открытой до конца 0.6.

### 0.6 SSH-харденинг

`/etc/ssh/sshd_config.d/00-hardening.conf` — именно `00-`: sshd берёт **первое**
значение директивы, а cloud-init кладёт `50-cloud-init.conf` с
`PasswordAuthentication yes`; файл `99-…` молча проиграет.

```bash
sudo tee /etc/ssh/sshd_config.d/00-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers <user>
MaxAuthTries 3
X11Forwarding no
EOF
sudo sshd -t && sudo systemctl restart ssh
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|maxauthtries)'
```

Проверить новый вход из второго терминала до закрытия первого.

В 24.04 SSH работает через `ssh.socket`: директива `Port` в sshd_config **игнорируется**.
Если человек всё же хочет другой порт — `sudo systemctl edit ssh.socket` с пустым
`ListenStream=` и новым `ListenStream=<порт>`, затем `daemon-reload` и restart
`ssh.socket`; и тот же порт — в облачный фаервол, ufw и jail fail2ban одновременно.

### 0.7 ufw

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'ssh'
sudo ufw enable
sudo ufw status verbose
```

Правила `(v6)` появятся и без IPv6 — не трогать.

### 0.8 fail2ban

```bash
sudo apt install -y fail2ban
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = 22
EOF
sudo systemctl restart fail2ban && sudo fail2ban-client status sshd
```

Без `backend = systemd` jail в 24.04 поднимается без ошибок и никогда не срабатывает:
`/var/log/auth.log` нет, логи только в journald. При входе по ключу fail2ban — гигиена
логов, а не рубеж. На Ubuntu 26.04+ (OpenSSH 9.8+, процесс `sshd-session`) проверить,
что jail продолжает видеть попытки.

### 0.9 Автообновления без автоперезагрузки

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
echo 'Unattended-Upgrade::Automatic-Reboot "false";' | sudo tee /etc/apt/apt.conf.d/52unattended-upgrades-local
apt-config dump | grep -i automatic-reboot
```

У apt побеждает **последний** файл — поэтому override `52-…`. Перезагрузка только
вручную, с проверкой модуля после (Этап 5): ночной ребут с несобравшимся DKMS-модулем —
это «утром интернет не работает».

### 0.10 Путь назад и снапшот

- **Сейчас** открыть веб-консоль хостера (Hetzner: сервер → Console) и войти под
  `<user>` по паролю. Это единственный путь назад после неудачного правила фаервола.
- Снапшот `vpn-stage0`.

### Приёмка Этапа 0

- [ ] вход по ключу под `<user>`, `sudo` работает
- [ ] `ssh -o PubkeyAuthentication=no <user>@<IP>` — отказ, пароль не спрашивается
- [ ] `ssh root@<IP>` — отказ
- [ ] `sudo ss -tulpn` — наружу слушает только sshd
- [ ] ufw: deny incoming, открыт только 22/tcp; облачный фаервол — тот же набор
- [ ] `ip -6 addr show scope global` — пусто
- [ ] `sudo fail2ban-client status sshd` — jail активен
- [ ] `sudo unattended-upgrades --dry-run --debug` — без ошибок
- [ ] веб-консоль проверена руками, снапшот снят

---

## Этап 1. AmneziaWG на сервере

### 1.1 Установка

```bash
sudo apt install -y linux-headers-$(uname -r) software-properties-common qrencode
sudo add-apt-repository -y ppa:amnezia/ppa
sudo apt install -y amneziawg amneziawg-tools
modinfo amneziawg | grep -E '^version'
sudo modprobe amneziawg && lsmod | grep amneziawg
awg --version
```

Если `modprobe` падает — DKMS не собрал модуль: см. troubleshooting.

### 1.2 Ключи сервера и обфускация

Скрипты из `scripts/` скопировать на сервер: с компьютера, где лежит этот репозиторий, —
`scp scripts/* vpn:/tmp/`; без локальной копии — скачать прямо на сервере и **прочитать
перед установкой**:

```bash
cd /tmp && for s in gen-obfs awg-add-peer awg-status; do
  curl -fsSLO https://raw.githubusercontent.com/kirzhanov/vpn-setup-skill/main/scripts/$s
done
less gen-obfs awg-add-peer awg-status
```

Затем:

```bash
sudo install -m 755 /tmp/gen-obfs /tmp/awg-add-peer /tmp/awg-status /usr/local/sbin/
sudo -i
cd /etc/amnezia/amneziawg && umask 077
awg genkey | tee server.key | awg pubkey > server.pub
gen-obfs > obfs.params
ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1 > endpoint    # публичный IPv4
cat endpoint
```

Параметры генерируются **один раз**. Ограничения, которые соблюдает `gen-obfs`:
`Jc` 3–10; `Jmin < Jmax`, 50–1000; `S1`, `S2` 15–150 и `S1 + 56 ≠ S2`; `H1–H4`
различны и > 4. Только классический набор `Jc/Jmin/Jmax/S1/S2/H1–H4` — его понимают
все клиенты, включая модули в прошивках роутеров. Новые параметры AmneziaWG 1.5/2.0
(`I1–I5`, `S3/S4`) не добавлять, пока все клиенты и роутер их не поддерживают.

Внешний интерфейс — `ip route show default` (на Hetzner Cloud `eth0`). Если другой —
поправить его в конфиге ниже и в правиле ufw.

### 1.3 Конфиг сервера

Собирается из файлов — приватный ключ не проходит через буфер обмена:

```bash
cat > awg0.conf <<EOF
[Interface]
Address = 10.9.0.1/24
ListenPort = 443
PrivateKey = $(cat server.key)
MTU = 1420
$(cat obfs.params)

PostUp   = iptables -t nat -A POSTROUTING -s 10.9.0.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.9.0.0/24 -o eth0 -j MASQUERADE
EOF
echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-awg.conf && sysctl --system | grep ip_forward
```

### 1.4 Фаервол

```bash
ufw allow 443/udp comment 'amneziawg'
ufw route allow in on awg0 out on eth0 comment 'awg -> internet'
```

И **UDP 443 в облачный фаервол** — без него пакеты режутся до машины, `awg show` молчит.
Не ставить `DEFAULT_FORWARD_POLICY="ACCEPT"`: нужен ровно один путь — туннель → интернет.

### 1.5 Запуск и первый клиент

```bash
systemctl enable --now awg-quick@awg0
awg show awg0
awg-add-peer laptop 10.9.0.2
```

`awg-add-peer` добавляет пира в `awg0.conf`, применяет без перезапуска туннеля, кладёт
клиентский конфиг в `/root/clients/<имя>.conf` и печатает QR.

Доставка конфига на устройство:
- **Телефон** — сканировать QR из терминала в приложении AmneziaWG.
- **Компьютер** — `ssh vpn 'sudo cat /root/clients/laptop.conf' > laptop.conf`,
  импортировать в приложение, затем удалить локальную копию.
- После импорта — **удалить с сервера**: `shred -u /root/clients/<имя>.conf`.
  Клиентский приватный ключ живёт только на устройстве; потерял устройство — новый пир.

Клиенты: Android / iOS / Windows / macOS — приложение **AmneziaWG**; Linux — приложение
**AmneziaVPN** (Ubuntu: нужен `libxcb-cursor0`) или `awg-quick`, если модуль ядра
собирается под ядро ноутбука. Штатный VPN NetworkManager **не работает**.

Проверка: `awg-status` на сервере — у пира свежий handshake и растёт трафик; на клиенте
`curl -4 ifconfig.me` возвращает IP сервера.

Снапшот `vpn-stage1`.

### Приёмка Этапа 1

- [ ] `modinfo amneziawg` и `lsmod` показывают модуль
- [ ] `systemctl is-enabled awg-quick@awg0` — enabled
- [ ] UDP 443 открыт в ufw и облачном фаерволе
- [ ] первый клиент: handshake свежий, внешний IP — сервера
- [ ] клиентский конфиг удалён с сервера, снапшот снят

---

## Этап 2. Гейт — до покупки железа

Единственная неустранимая неизвестность: выживет ли протокол у этого провайдера.
Роутер покупается после ответа.

Разовые замеры в первый день — **записать результаты в прогресс**:

- латентность: `ping -c 20 <IP>` (без туннеля) и `ping -c 20 1.1.1.1` (через туннель);
- **MTU**: через туннель `ping -M do -s 1372 1.1.1.1` (Linux; Windows: `ping -f -l 1372`),
  уменьшать размер, пока пакеты не пойдут; MTU = найденный размер + 28. Если меньше
  1420 — поправить `MTU` на сервере и в клиентских конфигах;
- скорость: speedtest через туннель, видео 1080p/4K;
- DNS: dnsleaktest.com — только резолвер из туннеля;
- IPv6: test-ipv6.com — либо «нет IPv6», либо адрес сервера, но не провайдера.

Потом **3–5 дней реального использования**, с вечерним прайм-таймом и видеозвонком,
по возможности через два разных оператора (домашний и мобильный). Блокировка редко
бывает мгновенной: DPI может рвать длинные потоки или срабатывать по статистике.
Один успешный `curl` ничего не доказывает.

**Гейт пройден**, если туннель держится несколько дней без разрывов, которые не
объясняются каналом. Если нет — роутер откладывается, работа идёт по «Если AmneziaWG
заблокируют» в конце.

Подключать остальные устройства можно уже здесь: `awg-add-peer <имя> 10.9.0.N`,
по пиру на устройство.

---

## Этап 3. Роутер GL.iNet

Только если гейт пройден и роутер нужен.

### 3.1 Покупка

Перед оплатой — на docs.gl-inet.com: модель в актуальном списке поддержки AmneziaWG и
для неё есть прошивка ≥ 4.9. По состоянию на сентябрь 2026 в списке Flint 2 (MT6000),
Flint 3, Brume 3, Beryl AX; Slate AX (AXT1800) — нет. Прошивка роутера может нести
старый модуль AmneziaWG — классический набор параметров с ним совместим, но
подтверждается только на железе.

### 3.2 Первичная настройка

1. Подключить WAN роутера к LAN роутера провайдера (DHCP-клиент). Мост на роутере
   провайдера не нужен: двойной NAT мешает только входящим соединениям.
2. Обновить прошивку до версии с AmneziaWG; **не восстанавливать** бэкап конфига со
   старой версии.
3. LAN роутера (по умолчанию `192.168.8.0/24`) не должен совпадать с подсетью провайдера.
4. Сменить пароль админки, выключить доступ к админке из WAN.
5. **IPv6 выключить** на WAN и LAN. Если провайдер раздаёт v6, а туннель v4-only,
   v6-трафик уйдёт мимо, и kill switch этого не увидит.

### 3.3 Пир роутера

На сервере: `awg-add-peer router 10.9.0.3`. Конфиг на компьютер, как в 1.5, MTU — из
гейта. В веб-интерфейсе роутера — раздел VPN → клиент AmneziaWG (точные названия
пунктов сверить с текущей документацией GL.iNet): импорт конфига, весь трафик в
туннель. Конфиг удалить с сервера и с компьютера после импорта.

### 3.4 Переключатели

- **Block Non-VPN Traffic** (kill switch) — включён
- автостарт VPN при загрузке
- никаких исключений в VPN Policy на старте

---

## Этап 4. Приёмка — экспериментами

**1. Kill switch при мёртвом туннеле и живом канале** — так и выглядит блокировка.
На сервере (второй терминал открыт — правило iptables не трогает SSH, но всё равно):

```bash
sudo iptables -I INPUT 1 -p udp --dport 443 -j DROP
sudo conntrack -D -p udp --dport 443        # пакет conntrack; сбросить текущие записи
```

С устройства в сети роутера при идущем `ping 1.1.1.1` и видео: трафик **прекращается**,
а не идёт напрямую; `curl -4 ifconfig.me` не возвращает IP провайдера. Затем:

```bash
sudo iptables -D INPUT -p udp --dport 443 -j DROP
```

— туннель восстанавливается сам.

**2. DNS и IPv6** — dnsleaktest.com и test-ipv6.com с устройства в сети роутера.
**3. Видеозвонок** через двойной NAT — соединяется, пусть и через relay.
**4. Перезагрузки** роутера и VPS — туннель поднимается без ручных действий.
**5. Быт** — сутки обычного использования: стриминг вечером, ТВ, консоль.

---

## Этап 5. Эксплуатация

- **После каждой перезагрузки VPS** (и после обновления ядра — перезагружать вручную):
  `modinfo amneziawg | grep version`, `sudo awg-status`.
- **Мониторинг**: systemd-таймер, проверяющий свежесть `awg show awg0 latest-handshakes`
  у роутера, с алертом в Telegram при простое > 10 минут. Собрать с человеком, если
  нужен; токен бота — в файл с правами 600, не в скрипт.
- **Бэкап**: `/etc/amnezia/amneziawg/` (ключ сервера, `obfs.params`, `awg0.conf`) — в
  менеджер паролей; снапшот после значимых изменений.
- **Потеря устройства**: удалить его `[Peer]` из `awg0.conf`, затем
  `sudo bash -c 'awg syncconf awg0 <(awg-quick strip awg0)'`. Остальных не трогать.

---

## Если AmneziaWG заблокируют

От дешёвого к дорогому:

1. Сменить UDP-порт (сервер, оба фаервола, все клиенты) и перегенерировать обфускацию.
2. Пересоздать сервер на новом IP из снапшота — старый мог попасть в списки.
3. Резерв Reality на личных устройствах (ниже).
4. Роутер на sing-box + VLESS+Reality — сторонние пакеты (podkop, homeproxy), без
   нативного GUI, с оговорками по UDP. План Б, не цель.

---

## Резерв: VLESS+Reality через 3x-ui на TCP/443

После гейта, в спокойном режиме — лучше заранее, чем когда всё уже не работает.
На этом сервере ещё не проверялось: команды установки брать из актуального README
3x-ui, не по памяти, и проверить, что скрипт с официального репозитория.

Что важно независимо от версии:
- TCP/443 и UDP/443 — разные сокеты, с AmneziaWG не конфликтуют. TCP 443 открыть в
  обоих фаерволах.
- **Панель 3x-ui наружу не публиковать.** Слушать на `127.0.0.1`, заходить через
  `ssh -L <порт>:127.0.0.1:<порт> vpn`. Логин и путь панели — сменить с дефолтных.
- Если панель или xray в Docker — опубликованные порты **обходят ufw** через iptables;
  закрывать через `DOCKER-USER` или привязку к `127.0.0.1`. Облачный фаервол это
  прикрывает — ещё один довод за два слоя.
- Цель маскировки (SNI) — крупный сайт с TLS 1.3 и HTTP/2, доступный из страны
  пользователя; проверить перед выбором.
- Клиенты: v2rayNG / Hiddify (Android), Streisand / Hiddify (iOS), Hiddify / NekoBox
  (десктоп) — сверить актуальность.

## Что осознанно не делаем

- Не переводим роутер провайдера в мост — пока не нужен проброс портов в VPN-сеть.
- Не держим OpenVPN резервом — тяжелее и блокируется не хуже.
- Не тащим умный дом в туннель — локальные протоколы ломаются.
- Не ставим панели управления сервером (Webmin и т. п.) — лишняя точка входа.
- Не выключаем ufw «на время отладки» — отладка со второй сессией, а не без защиты.
