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
./contador_udp_zabbix --port-range 5001-5005 --http-port 8080 \
  --auth-token "meu-token-secreto"
```

Teste:

```bash
curl -H "Authorization: Bearer meu-token-secreto" \
  http://127.0.0.1:8080/zabbix/cam5001/last/value
```

## Flags

| Flag | Default | Descrição |
|---|---|---|
| `--camera nome:porta` | — | Câmera manual; pode repetir |
| `--port-range a-b` | — | Cria listener por porta no range |
| `--counter-prefix` | `cam` | Prefixo dos nomes gerados pelo range |
| `--http-host` | `0.0.0.0` | Bind HTTP |
| `--http-port` | `8080` | Porta HTTP |
| `--udp-host` | `0.0.0.0` | Bind UDP |
| `--bucket-seconds` | `60` | Tamanho do bucket (Zabbix lê o último fechado) |
| `--active` | `high` | `high` = !=0 é ativo; `low` inverte |
| `--auth-token` | (vazio) | Token; vazio desativa auth |
| `--allowed-source-cidr` | — | Filtra IPs de origem; pode repetir |
| `--debug` | `false` | Loga cada pacote recebido |

`--camera` e/ou `--port-range` são obrigatórios. Veja todas com
`./contador_udp_zabbix --help`.

## Rotas

- `GET /zabbix/{camera}/last/value` — número (recomendado para Zabbix)
- `GET /zabbix/{camera}/last` — JSON do último bucket fechado
- `GET /zabbix/ip/{ip}/last[/value]` — portas onde o IP apareceu
- `GET /health` · `GET /identity` · `GET /cameras` · `GET /debug[/{camera}]`
