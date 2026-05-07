# Contador UDP -> Zabbix

Serviço em Go (arquivo único `contador_udp_zabbix.go`) que recebe pulsos UDP
de câmeras Pumatronix/ITSCAM (ou equivalentes), conta veículos por **borda de
pulso** (transição inativo → ativo), agrupa por minuto fechado e expõe rotas
HTTP GET para o Zabbix coletar.

Sem banco, sem Redis, sem Prometheus, sem framework externo. Apenas a
biblioteca padrão do Go.

---

## Sumário

- [Arquitetura](#arquitetura)
- [Por que separar por porta UDP](#por-que-separar-por-porta-udp)
- [Lógica de contagem](#lógica-de-contagem)
- [Parsing dos pacotes](#parsing-dos-pacotes)
- [Como rodar](#como-rodar)
- [Flags](#flags)
- [Rotas HTTP](#rotas-http)
- [Autorização (token)](#autorização-token)
- [Configurando as câmeras](#configurando-as-câmeras)
- [Configurando o Zabbix](#configurando-o-zabbix)
- [Limitações](#limitações)
- [Possíveis otimizações futuras em Go](#possíveis-otimizações-futuras-em-go)

---

## Arquitetura

```
 cam Entrada ──UDP:19000──┐
 cam Saída   ──UDP:19001──┤      ┌──────────────────────────┐
 cam Pátio   ──UDP:19002──┼──►   │  contador_udp_zabbix     │
                         │      │                          │
                         │      │  - 1 listener UDP/porta  │
                         │      │  - 1 Counter/listener    │
                         │      │  - bucket atual + último │
                         │      │    bucket fechado em RAM │
                         │      │                          │
                         │      │  HTTP /zabbix/...  ──► Zabbix HTTP Agent
                         │      └──────────────────────────┘
```

Cada câmera/contador tem um `Counter` próprio com mutex próprio. Cada porta
UDP roda em sua própria goroutine. O servidor HTTP roda no processo
principal.

Em RAM, por contador:

- nome, porta UDP, tamanho do bucket (segundos)
- bucket atual (start + count)
- último bucket fechado (start + end + count)
- total geral, pacotes recebidos/ignorados
- estado anterior (ativo/inativo) e flag de "primeiro pacote já recebido"
- mapa de IPs de origem já vistos neste listener (somente diagnóstico)

---

## Por que separar por porta UDP

Algumas câmeras chegam **com o mesmo IP de origem** quando há NAT, VPN,
roteador ou link compartilhado. Por isso a identidade da câmera **não é** o
IP de origem, e sim a **porta UDP local** onde ela envia o pulso.

```
cam entrada ─► servidor:19000
cam saída   ─► servidor:19001
cam pátio   ─► servidor:19002
```

Mesmo que todas saiam do mesmo IP público, o serviço separa pela porta
local de chegada. O IP de origem é gravado **apenas para diagnóstico** e
para a rota de consulta por IP.

---

## Lógica de contagem

A contagem acontece **somente** na transição:

```
estado anterior = inativo
estado atual    = ativo   ──► count++
```

```
0 0 1 1 1 0 0   = 1 veículo
0 1 0 1 0       = 2 eventos
```

Cuidado com o **primeiro pacote** após o serviço subir: se ele já vier
ativo, apenas sincronizamos `previousActive = true` **sem contar**. Isso
evita falso positivo se o serviço iniciar no meio de um pulso.

> Esta versão **não** implementa `--min-gap-ms`. A contagem por borda já
> resolve o caso normal; usar gap mínimo poderia esconder veículos reais em
> fluxo intenso.

### Bucket / período

O Zabbix consulta o **último bucket fechado**, nunca o atual.

```
agora            = 14:32:20
bucket atual     = 14:32:00 .. 14:32:59  (incompleto)
último fechado   = 14:31:00 .. 14:31:59  ◄── /zabbix/.../last/value retorna isto
```

Se nenhum pacote chegar por minutos, ao consultar a aplicação **rotaciona o
estado temporal** e retorna o minuto imediatamente anterior ao atual com
`count = 0` (não houve eventos).

---

## Parsing dos pacotes

Função `parsePulsePayload(data []byte) (int, bool)`. Tenta, na ordem:

1. **Texto** (case-insensitive, com trim):
   `"1"`, `"true"`, `"ativo"`, `"active"`, `"high"`, `"alto"` → `1`
   `"0"`, `"false"`, `"inativo"`, `"inactive"`, `"low"`, `"baixo"` → `0`
2. **Binário big-endian** de 1, 2, 4 ou 8 bytes: zero → 0, qualquer outro
   valor → 1.
3. **Fallback**: qualquer byte != 0 em qualquer tamanho → 1.

O modo `--active` define a polaridade:

- `high` (padrão): valor != 0 = ativo (`80 00 00 00` = ativo, `00 00 00 00` = inativo).
- `low`: invertido.

---

## Como rodar

```bash
# build
go build -o contador_udp_zabbix contador_udp_zabbix.go

# três câmeras nomeadas
./contador_udp_zabbix \
  --camera entrada:19000 \
  --camera saida:19001 \
  --camera patio:19002 \
  --http-port 23187 \
  --bucket-seconds 60 \
  --active high \
  --auth-token "meu-token-secreto" \
  --debug

# range de portas (gera cam19000..cam19049)
./contador_udp_zabbix \
  --port-range 19000-19049 \
  --counter-prefix cam \
  --http-port 23187 \
  --bucket-seconds 60 \
  --active high \
  --auth-token "meu-token-secreto"

# range + filtro de origem
./contador_udp_zabbix \
  --port-range 19000-19049 \
  --counter-prefix cam \
  --http-port 23187 \
  --auth-token "meu-token-secreto" \
  --allowed-source-cidr 192.168.0.0/16 \
  --allowed-source-cidr 10.0.0.0/8
```

---

## Flags

| Flag | Default | Descrição |
|---|---|---|
| `--http-host` | `0.0.0.0` | Bind HTTP |
| `--http-port` | `23187` | Porta HTTP |
| `--udp-host` | `0.0.0.0` | Bind UDP |
| `--bucket-seconds` | `60` | Tamanho do bucket em segundos |
| `--active` | `high` | `high` ou `low` |
| `--auth-token` | (vazio) | Token de autorização. Vazio = sem auth |
| `--camera` | — | `nome:porta`, pode repetir |
| `--port-range` | — | `inicio-fim`, ex: `19000-19049` |
| `--counter-prefix` | `cam` | Prefixo de nome para `--port-range` |
| `--allowed-source-cidr` | — | CIDR permitido como origem (pode repetir) |
| `--debug` | `false` | Loga cada pacote recebido |

Validações executadas no boot:

- nome ou porta duplicados
- porta inválida / formato inválido
- `bucket-seconds <= 0`
- `active` diferente de `high`/`low`
- CIDR inválido
- nenhuma câmera definida
- erro ao abrir listener UDP → encerra com erro claro

`--port-range` e `--camera` podem ser usados juntos; conflitos são
detectados.

---

## Rotas HTTP

Todas as rotas aceitam apenas `GET`. Se `--auth-token` estiver definido,
todas exigem token (inclusive `/health`, por simplicidade — basta enviar o
token).

| Rota | Tipo | Descrição |
|---|---|---|
| `GET /health` | JSON | `{"ok": true}` |
| `GET /identity` | JSON | Configuração efetiva e câmeras |
| `GET /cameras` | JSON | Lista de câmeras |
| `GET /zabbix/{camera}/last` | JSON | Último bucket fechado da câmera |
| `GET /zabbix/{camera}/last/value` | text | Apenas o número (recomendado p/ Zabbix) |
| `GET /zabbix/ip/{source_ip}/last` | JSON | Todas as portas onde o IP apareceu + count |
| `GET /zabbix/ip/{source_ip}/last/value` | text | `porta=count` por linha |
| `GET /debug` | JSON | Estado completo de todos os contadores |
| `GET /debug/{camera}` | JSON | Estado completo de um contador |

### Exemplos

```bash
# saúde
curl http://SERVIDOR:23187/health

# valor da câmera (recomendado p/ Zabbix)
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/cam19000/last/value
# => 12

# JSON da câmera
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/cam19000/last

# por IP de origem (todos os listeners onde aquele IP apareceu)
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/ip/192.168.1.20/last

# por IP em texto puro
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/ip/192.168.1.20/last/value
# => 19000=12
#    19001=4

# debug
curl -H "X-Auth-Token: meu-token-secreto" \
  http://SERVIDOR:23187/debug

# query string (apenas para teste — desencorajado em produção)
curl "http://SERVIDOR:23187/zabbix/cam19000/last/value?token=meu-token-secreto"
```

#### Resposta de `/zabbix/ip/{ip}/last`

```json
{
  "ok": true,
  "source_ip": "192.168.1.20",
  "bucket_seconds": 60,
  "matches": [
    {
      "camera": "cam19000",
      "udp_port": 19000,
      "bucket_seconds": 60,
      "bucket_start_ts": 1778167140,
      "bucket_end_ts": 1778167200,
      "bucket_start": "2026-05-07T14:31:00",
      "bucket_end": "2026-05-07T14:32:00",
      "count": 12,
      "total": 350,
      "packets_received": 900,
      "last_seen": "2026-05-07T14:32:01"
    }
  ]
}
```

Se o IP não apareceu em nenhum listener, `matches` vem vazio
(`/last/value` retorna corpo vazio).

---

## Autorização (token)

Se `--auth-token` for informado, toda requisição precisa enviar o token
por **uma** destas formas:

1. `Authorization: Bearer TOKEN` (recomendado)
2. `X-Auth-Token: TOKEN`
3. `?token=TOKEN` (apenas para teste — pode vazar em logs)

Erro:

```
HTTP 401 Unauthorized
{"ok": false, "error": "unauthorized"}
```

No Zabbix, configure o token via **Headers** do item HTTP Agent — nunca
via URL em produção.

---

## Configurando as câmeras

Cada câmera Pumatronix/ITSCAM deve ser configurada para enviar o pulso
UDP para o IP do servidor e para uma **porta única** por câmera.

```
cam Entrada → servidor:19000
cam Saída   → servidor:19001
cam Pátio   → servidor:19002
```

Não importa se duas câmeras chegam com o mesmo IP de origem (NAT/VPN): o
serviço identifica pela **porta de destino**.

Se quiser restringir quem pode enviar, use `--allowed-source-cidr`. Isto é
**filtro de segurança**, não identidade.

---

## Configurando o Zabbix

### Item por câmera (recomendado)

- Tipo: **HTTP Agent**
- Método: `GET`
- URL: `http://SERVIDOR:23187/zabbix/cam19000/last/value`
- Headers: `Authorization: Bearer meu-token-secreto`
- Tipo de informação: **Numeric (unsigned)**
- Intervalo: `60s`
- Preprocessing: nenhum (resposta já é o número)

A resposta é o **último minuto fechado**, não o minuto atual incompleto —
isto garante que o Zabbix sempre receba um valor estável.

### Por IP de origem (diagnóstico / múltiplas portas)

`/zabbix/ip/{ip}/last` (JSON) é útil para diagnosticar quando várias
câmeras chegam com o mesmo IP público. Para coletar várias portas em uma
chamada, configure um master item **HTTP Agent** consultando a rota JSON
e use **dependent items** com preprocessing JSONPath, ou evolua depois
para LLD.

---

## Limitações

- **Apenas o último minuto fechado** é mantido. Se o Zabbix perder uma
  coleta, aquele minuto se perde.
- **Sem persistência**: reinício do processo zera contadores.
- **Sem TLS**: coloque atrás de Nginx/Caddy se precisar de HTTPS.
- **Sem `--min-gap-ms`** nesta versão (intencional).
- **Sem LLD pronto** para Zabbix (descoberta automática) — pode ser
  evoluído.
- **Sem graceful shutdown** sofisticado — o processo encerra ao receber
  sinal e perde o bucket atual.

---

## Possíveis otimizações futuras em Go

1. Usar canais Go para desacoplar leitura UDP e processamento.
2. Worker pool quando há muitas câmeras.
3. `net.ListenConfig` para opções avançadas de socket (SO_REUSEPORT etc).
4. Buffer/channel por câmera para evitar bloqueio em picos.
5. Exportar métricas Prometheus.
6. `systemd` service para rodar como daemon.
7. Persistência opcional em SQLite/PostgreSQL para histórico longo.
8. Endpoint multi-valor para Zabbix discovery / LLD.
9. LLD do Zabbix para descoberta automática dos contadores.
10. Config YAML/JSON (mantendo flags como atalho).
11. Graceful shutdown com `context` + `signal.Notify`.
12. Otimização de alocação no parsing para volume muito alto.
13. Histórico circular em RAM para recuperar coletas perdidas.
14. Métricas por IP de origem sem comprometer a identidade por porta.
15. TLS nativo ou Nginx/Caddy na frente.
