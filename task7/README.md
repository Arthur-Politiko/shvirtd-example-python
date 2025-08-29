## Задача 7: запуск Python-приложения с runc (без Docker/Containerd)

Запустите ваше Python‑приложение при помощи runc, не используя Docker или containerd. Приложите скриншоты действий.

### Наивный путь: chroot и почему он не подходит

Первое, что приходит в голову, — повторить подход замены корня (chroot).

1. Создадим папку `iloverunc/rootfs`.
2. Подготовим минимальную структуру каталогов:

```bash
cd iloverunc
mkdir -p rootfs/{bin,dev,proc,sys,etc,usr,lib,tmp,var}
```

3. Смонтируем системные каталоги:

```bash
for i in dev proc sys; do sudo mount --bind /$i rootfs/$i; done
```

4. Проверим зависимости командного интерпретатора `/bin/bash`:

```bash
ldd rootfs/bin/bash
```

Пример вывода:

```
linux-vdso.so.1 (0x00007fffbb5c9000)
libtinfo.so.6 => /lib/x86_64-linux-gnu/libtinfo.so.6 (0x000078436d5bd000)
libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x000078436d200000)
/lib64/ld-linux-x86-64.so.2 (0x000078436d765000)
```

Попытка «дотащить» бинарники и их зависимости вручную и затем сделать `chroot`:

```bash
chroot ./rootfs /bin/bash -c "apt update && apt install -y python3 pip && apt clean"
```

Приводит к ошибке вида `E: Error reading the CPU table`.
Причина — Debian‑бинарники зависят от богатой файловой базы (dpkg, apt и сопутствующие данные/скрипты). Вручную вытаскивать всё — почти как собирать мини‑Debian руками.

Фрагмент `strace` для `apt` внутри такого окружения:

```
newfstatat(AT_FDCWD, "/etc/apt/apt.conf", ...) = -1 ENOENT
newfstatat(AT_FDCWD, "/var/lib/dpkg/status", ...) = -1 ENOENT
openat(AT_FDCWD, "/usr/share/dpkg/cputable", O_RDONLY) = -1 ENOENT
...
Error reading the CPU table
```

Вывод: `chroot` — не контейнер. Он лишь меняет корень `/`, остальное (ядро, сеть и т.п.) общее с хостом. Для полноценного rootfs используем `debootstrap`.

### Правильный путь: debootstrap

Установим базовую систему Debian в `rootfs`:

```bash
debootstrap stable ./rootfs http://deb.debian.org/debian/
```

На выходе — ~300 МБ необходимых бинарников, скриптов и конфигурации.

Подмонтируем каталоги и «зайдём» внутрь:

```bash
for i in dev proc sys; do sudo mount --bind /$i rootfs/$i; done
chroot rootfs/
```

Теперь всё работает, есть и сеть. Но это всё ещё не изоляция контейнера — вернёмся к этому через `runc`.

### Генерация и правка runc spec

Создадим базовый `config.json`:

```bash
runc spec
```

Что стоит изменить:

- при необходимости убрать/добавить `network` namespace;
- в `process.args` выставить нужную команду (для интерактивной оболочки — `bash`);
- `root.readonly` установить в `false`;
- для запуска «в фоне» отключить TTY и задать бесконечный процесс:

```json
"process": {
  "terminal": false,
  "args": ["sleep", "infinity"]
}
```

Старт контейнера:

```bash
runc run -d task7-container
runc list
runc exec task7-container bash
```

Полезные материалы:

- https://blog.quarkslab.com/digging-into-runtimes-runc.html
- https://habr.com/ru/companies/selectel/articles/316258/

### Сетевая изоляция: veth + namespace

Вернём `network` namespace в `config.json` (`linux.namespaces`). Создадим veth‑пару и подключим один конец в netns процесса контейнера:

```bash
ip link add veth0 type veth peer name ceth0
ip link set veth0 up
ip addr add 172.20.0.100/24 dev veth0

# Узнаём PID контейнера
sudo runc list

# Подключаем peer к netns контейнера
ip link set ceth0 netns /proc/<PID>/ns/net
```

Далее внутри контейнера (или из хоста через `nsenter`):

```bash
sudo nsenter --target <PID> --net
ip link set ceth0 up
ip addr add 172.20.0.5/24 dev ceth0
ip route add default via 172.20.0.1 dev ceth0
ping -c 1 172.20.0.100
```

Чтобы работал выход в Интернет (на хосте):

```bash
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward
sudo iptables -t nat -A POSTROUTING -s 172.20.0.0/24 -j MASQUERADE
```

DNS внутри контейнера:

```bash
echo "nameserver 8.8.8.8" > /etc/resolv.conf
```

Примечание про права: для сетевых операций из контейнера нужны `CAP_NET_ADMIN` и `CAP_NET_RAW` (укажите их в `process.capabilities`). Альтернатива — настраивать сеть с хоста через `nsenter`.

### Интеграция с сетью Docker (для связи с MySQL)

Если MySQL запущен через Docker Compose, можно подключить `veth0` к мосту Docker:

```bash
# Узнайте имя моста (например, через `docker network ls`/`ip link`)
sudo ip link set veth0 master br-<bridge-id>
```

Это позволит `runc`‑контейнеру видеть контейнеры в той же подсети.

### Установка Python и запуск приложения внутри контейнера

```bash
apt update
apt install -y python3 python3-venv python3-pip

export DB_HOST=172.20.0.10
export DB_USER=app
export DB_PASSWORD=QwErTy1234
export DB_NAME=virtd

python3 -m venv task7-env
source task7-env/bin/activate
uvicorn main:app --host 0.0.0.0 --port 5000 --reload
```

Проверка из другого терминала:

```bash
curl 127.0.0.1:8090
```

### Итоги и автоматизация

- Для настройки сети в `runc` удобно использовать `hooks.poststart` и вызывать скрипт, который делает все сетевые шаги автоматически.
- Для подключения к сети Docker лучше входить в соответствующий namespace мостовой сети, чем жёстко привязываться к имени моста.
- Переменные окружения можно пробрасывать через общий каталог или `process.env` в `config.json`.
- Автоматический зауск проекта можно организовать изменив в config.json секцию
  а так же указав рабочую директорию, к примеру /app и сложив туда необходимые файлы проекта

```json
"process": {  
	"args": [
			"uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000", "--reload""sleep", "infinity
		]
}
```


![its work](./img/5.7.png)
