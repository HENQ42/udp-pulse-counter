# contador-udp-zabbix

Serviço Go que recebe pulsos UDP de câmeras e expõe contagem de veículos
por HTTP para o Zabbix. Documentação completa:
[`README_CONTADOR_UDP.md`](./README_CONTADOR_UDP.md).

## Compilar

```bash
go build -o contador_udp_zabbix contador_udp_zabbix.go
```

## Rodar

```bash
./contador_udp_zabbix --port-range 5000-5249 \
  --http-host 127.0.0.1 --http-port 23187
```

Teste:

```bash
curl http://127.0.0.1:23187/zabbix/cam5000/total/value
```

A resposta é o **contador monotônico** (total acumulado desde sempre). O
Zabbix calcula o delta por intervalo com preprocessing **Simple change**
ou **Change per second**.

## Flags

| Flag | Default | Descrição |
|---|---|---|
| `--camera nome:porta` | — | Câmera manual; pode repetir |
| `--port-range a-b` | — | Cria listener por porta no range |
| `--counter-prefix` | `cam` | Prefixo dos nomes gerados pelo range |
| `--http-host` | `0.0.0.0` | Bind HTTP |
| `--http-port` | `23187` | Porta HTTP |
| `--udp-host` | `0.0.0.0` | Bind UDP |
| `--active` | `high` | `high` = !=0 é ativo; `low` inverte |
| `--auth-token` | (vazio) | Token de auth HTTP. Não necessário se HTTP estiver em `127.0.0.1` |
| `--allowed-source-cidr` | — | Filtra IPs de origem; pode repetir |
| `--state-file` | (vazio) | Arquivo JSON para persistir contadores; vazio = desativa |
| `--persist-interval` | `60s` | Intervalo entre snapshots quando houver mudança |
| `--max-source-ips` | `64` | Limite de IPs de origem rastreados por contador |
| `--debug` | `false` | Loga cada pacote recebido |

`--camera` e/ou `--port-range` são obrigatórios. Veja todas com
`./contador_udp_zabbix --help`.

## Rotas

- `GET /zabbix/{camera}/total/value` — número (recomendado para Zabbix)
- `GET /zabbix/{camera}/total` — JSON com `total`, `udp_port`, `last_seen`
- `GET /zabbix/ip/{ip}/total[/value]` — portas onde o IP apareceu
- `GET /health` · `GET /identity` · `GET /cameras` · `GET /debug[/{camera}]`

As rotas antigas `/zabbix/.../last[/value]` continuam funcionando como
alias para `/total[/value]` (o valor retornado é o mesmo `total`
monotônico).

## Instalar como serviço (systemd)

### Modo automático (recomendado)

Use o script `install.sh`. Requer Go já instalado e roda como root:

```bash
sudo ./install.sh
```

O script:

- Verifica que é Ubuntu/Debian com systemd e Go disponível.
- Para o serviço se já estiver rodando.
- Limpa apenas arquivos do próprio projeto (`/opt/contador-udp/`,
  `/etc/systemd/system/contador-udp.service`,
  `/etc/sysctl.d/99-contador-udp.conf`).
- Compila o binário (`CGO_ENABLED=0 -ldflags="-s -w"`).
- Instala em `/opt/contador-udp/` como `root:root` com modo `0755`.
- Reserva o range UDP `5000-5249` via sysctl
  (`net.ipv4.ip_local_reserved_ports`).
- Cria o unit com hardening (`User=nobody`, `ProtectSystem=strict`,
  `NoNewPrivileges`, etc.), defaults:
  `--http-host 127.0.0.1 --http-port 23187 --port-range 5000-5249`.
- HTTP fica **localhost-only** (Zabbix consulta no próprio servidor),
  por isso a aplicação roda sem token de autorização.
- `daemon-reload`, `enable` e `restart`.
- Idempotente: rodar de novo apenas atualiza.

Verifique:

```bash
systemctl status contador-udp
journalctl -u contador-udp -f
curl http://127.0.0.1:23187/health
```

### Modo manual

1. Copie o binário para um diretório do sistema:

   ```bash
   sudo mkdir -p /opt/contador-udp
   sudo cp contador_udp_zabbix /opt/contador-udp/
   sudo chmod +x /opt/contador-udp/contador_udp_zabbix
   ```

2. Crie o unit em `/etc/systemd/system/contador-udp.service`:

   ```ini
   [Unit]
   Description=Contador UDP -> Zabbix
   After=network.target

   [Service]
   Type=simple
   User=nobody
   ExecStart=/opt/contador-udp/contador_udp_zabbix \
     --port-range 5000-5249 \
     --counter-prefix cam \
     --http-host 127.0.0.1 \
     --http-port 23187 \
     --bucket-seconds 60 \
     --active high
   Restart=always
   RestartSec=3

   [Install]
   WantedBy=multi-user.target
   ```

3. Habilite e inicie:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now contador-udp
   ```

4. Verifique status e logs:

   ```bash
   sudo systemctl status contador-udp
   sudo journalctl -u contador-udp -f
   ```

Para alterar flags depois: edite o unit, rode
`sudo systemctl daemon-reload && sudo systemctl restart contador-udp`.
