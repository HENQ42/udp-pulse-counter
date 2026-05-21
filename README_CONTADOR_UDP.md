# Contador UDP -> Zabbix

Serviço em Go (arquivo único `contador_udp_zabbix.go`) que recebe pulsos UDP
de câmeras Pumatronix/ITSCAM (ou equivalentes), conta veículos por **borda de
pulso** (transição inativo → ativo) e expõe um **contador monotônico** via
HTTP. O Zabbix calcula o delta por intervalo com preprocessing
**Simple change**.

O estado é **persistido em JSON** (snapshot periódico + flush em SIGTERM), de
modo que reinícios do processo não zeram a contagem.

Sem banco, sem Redis, sem Prometheus, sem framework externo. Apenas a
biblioteca padrão do Go.

---

## Sumário

- [Arquitetura](#arquitetura)
- [Por que separar por porta UDP](#por-que-separar-por-porta-udp)
- [Lógica de contagem](#lógica-de-contagem)
- [Persistência](#persistência)
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
 cam Entrada ──UDP:5000──┐
 cam Saída   ──UDP:5001──┤      ┌──────────────────────────┐
 cam Pátio   ──UDP:5002──┼──►   │  contador_udp_zabbix     │
                         │      │                          │
                         │      │  - 1 listener UDP/porta  │
                         │      │  - 1 Counter/listener    │
                         │      │  - Total monotônico      │
                         │      │  - state.json (snapshot) │
                         │      │                          │
                         │      │  HTTP /zabbix/...  ──► Zabbix HTTP Agent
                         │      └──────────────────────────┘
```

Cada câmera/contador tem um `Counter` próprio com mutex próprio. Cada porta
UDP roda em sua própria goroutine. O servidor HTTP roda no processo
principal. Uma goroutine adicional faz o snapshot periódico do estado.

Em RAM, por contador:

- nome, porta UDP
- `Total` (contador monotônico de eventos)
- `PacketsReceived` / `PacketsIgnored` (diagnóstico)
- estado anterior (ativo/inativo) e flag de "primeiro pacote já recebido"
- mapa bounded de IPs de origem já vistos neste listener (diagnóstico)

---

## Por que separar por porta UDP

Algumas câmeras chegam **com o mesmo IP de origem** quando há NAT, VPN,
roteador ou link compartilhado. Por isso a identidade da câmera **não é** o
IP de origem, e sim a **porta UDP local** onde ela envia o pulso.

```
cam entrada ─► servidor:5000
cam saída   ─► servidor:5001
cam pátio   ─► servidor:5002
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

### Contador monotônico

`Total` é incrementado a cada borda contada e **nunca decrementa em runtime**.
A rota HTTP devolve o valor absoluto atual. O Zabbix calcula a diferença
entre coletas com preprocessing **Simple change**.

```
t0  GET /zabbix/cam5000/total/value  ─►  184523
t1  GET /zabbix/cam5000/total/value  ─►  184537   (Simple change → 14 carros)
t2  GET /zabbix/cam5000/total/value  ─►  184537   (Simple change →  0 carros)
t3  GET /zabbix/cam5000/total/value  ─►  184562   (Simple change → 25 carros)
```

Vantagens em relação a uma janela fixa:

- **GET idempotente.** `curl` de teste, healthcheck duplicado, debug — nada
  altera o estado.
- **Intervalo de coleta livre.** 10 s, 60 s, 5 min: o delta é sempre correto.
- **Outage do Zabbix não distorce o histórico.** Quando o coletor volta, o
  primeiro delta cobre todo o intervalo perdido.
- **Tolerante a perda de pacote de resposta.** A próxima coleta absorve o
  evento naturalmente.

Quando o `Total` **diminui** (restart sem `state.json` válido), o preprocessing
`Simple change` do Zabbix descarta o ponto automaticamente.

---

## Persistência

O estado é gravado em um arquivo JSON único (default `/var/lib/contador-udp/state.json`).

- **Snapshot periódico** (default 60 s, configurável por `--persist-interval`).
  Só escreve se houve mudança desde o último snapshot (*dirty bit*).
- **Flush no SIGTERM/SIGINT** garante zero perda em restart planejado.
- **Write atômico:** `os.CreateTemp` + `fsync` + `rename` no mesmo diretório.
- **Recovery no boot:** carrega `Total`, `PacketsReceived` e `PacketsIgnored`
  por nome de câmera. Arquivo ausente, vazio ou corrompido **não trava** o
  boot — apenas loga aviso e começa do zero.
- **Câmera removida da config:** entrada órfã no disco é logada e ignorada.

Janela máxima de perda em crash não-graceful: o intervalo de `--persist-interval`.

Para **desativar** a persistência basta deixar `--state-file` vazio (default).

Estrutura do arquivo:

```json
{
  "version": 1,
  "saved_at": "2026-05-21T19:38:42Z",
  "counters": {
    "cam5000": {
      "udp_port": 5000,
      "total": 184523,
      "packets_received": 901234,
      "packets_ignored": 0
    }
  }
}
```

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

# três câmeras nomeadas, com persistência
./contador_udp_zabbix \
  --camera entrada:5000 \
  --camera saida:5001 \
  --camera patio:5002 \
  --http-port 23187 \
  --active high \
  --state-file ./state.json \
  --persist-interval 60s \
  --auth-token "meu-token-secreto" \
  --debug

# range de portas (gera cam5000..cam5249)
./contador_udp_zabbix \
  --port-range 5000-5249 \
  --counter-prefix cam \
  --http-port 23187 \
  --active high \
  --state-file /var/lib/contador-udp/state.json \
  --auth-token "meu-token-secreto"

# range + filtro de origem, sem persistência (--state-file vazio)
./contador_udp_zabbix \
  --port-range 5000-5249 \
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
| `--active` | `high` | `high` ou `low` |
| `--auth-token` | (vazio) | Token de autorização. Vazio = sem auth |
| `--camera` | — | `nome:porta`, pode repetir |
| `--port-range` | — | `inicio-fim`, ex: `5000-5249` |
| `--counter-prefix` | `cam` | Prefixo de nome para `--port-range` |
| `--allowed-source-cidr` | — | CIDR permitido como origem (pode repetir) |
| `--state-file` | (vazio) | Arquivo JSON para persistência; vazio = desativa |
| `--persist-interval` | `60s` | Intervalo entre snapshots quando houver mudança |
| `--max-source-ips` | `64` | Limite de IPs de origem rastreados por contador |
| `--debug` | `false` | Loga cada pacote recebido |

Validações executadas no boot:

- nome ou porta duplicados
- porta inválida / formato inválido
- `persist-interval <= 0`
- `max-source-ips <= 0`
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
| `GET /zabbix/{camera}/total` | JSON | `total` monotônico da câmera |
| `GET /zabbix/{camera}/total/value` | text | Apenas o número (recomendado p/ Zabbix) |
| `GET /zabbix/ip/{source_ip}/total` | JSON | Todas as portas onde o IP apareceu + total |
| `GET /zabbix/ip/{source_ip}/total/value` | text | `porta=total` por linha |
| `GET /debug` | JSON | Estado completo de todos os contadores |
| `GET /debug/{camera}` | JSON | Estado completo de um contador |

As rotas legadas `/zabbix/.../last[/value]` continuam funcionando como
**alias** para `/total[/value]`. O valor retornado é o mesmo `total`
monotônico — a semântica do campo mudou em relação à versão de buckets
fixos, e o Zabbix precisa ter preprocessing **Simple change** configurado.

### Exemplos

```bash
# saúde
curl http://SERVIDOR:23187/health

# valor da câmera (recomendado p/ Zabbix — número absoluto, monotônico)
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/cam5000/total/value
# => 184523

# JSON da câmera
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/cam5000/total

# por IP de origem (todos os listeners onde aquele IP apareceu)
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/ip/192.168.1.20/total

# por IP em texto puro
curl -H "Authorization: Bearer meu-token-secreto" \
  http://SERVIDOR:23187/zabbix/ip/192.168.1.20/total/value
# => 5000=184523
#    5001=  4711

# debug
curl -H "X-Auth-Token: meu-token-secreto" \
  http://SERVIDOR:23187/debug

# query string (apenas para teste — desencorajado em produção)
curl "http://SERVIDOR:23187/zabbix/cam5000/total/value?token=meu-token-secreto"
```

#### Resposta de `/zabbix/{camera}/total`

```json
{
  "ok": true,
  "camera": "cam5000",
  "udp_port": 5000,
  "total": 184523,
  "packets_received": 901234,
  "last_seen": "2026-05-21T14:32:01",
  "last_event_at": "2026-05-21T14:32:00"
}
```

#### Resposta de `/zabbix/ip/{ip}/total`

```json
{
  "ok": true,
  "source_ip": "192.168.1.20",
  "matches": [
    {
      "camera": "cam5000",
      "udp_port": 5000,
      "total": 184523,
      "packets_received": 901234,
      "last_seen": "2026-05-21T14:32:01",
      "last_event_at": "2026-05-21T14:32:00"
    }
  ]
}
```

Se o IP não apareceu em nenhum listener, `matches` vem vazio
(`/total/value` retorna corpo vazio).

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
cam Entrada → servidor:5000
cam Saída   → servidor:5001
cam Pátio   → servidor:5002
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
- URL: `http://SERVIDOR:23187/zabbix/cam5000/total/value`
- Headers: `Authorization: Bearer meu-token-secreto` (apenas se `--auth-token`)
- Tipo de informação: **Numeric (unsigned)**
- Intervalo: livre (60 s, 5 min, qualquer valor)
- **Preprocessing:**
  1. **Simple change** — entrega o delta entre coletas (carros no período)

> ⚠️ Sem `Simple change` o item armazena o contador absoluto e o gráfico
> vira uma reta crescente. **Sempre** configure o preprocessing.

Alternativas:

- **Change per second** no lugar de `Simple change`: entrega fluxo
  instantâneo em carros/segundo. Útil para dashboards de fluxo, mas perde
  a noção de "carros no período de coleta".
- **Discard unchanged** após `Simple change`: economiza histórico quando
  a câmera fica ociosa por longos períodos (madrugada).

### Item dependente a partir do JSON

Se preferir coletar com a rota JSON (ex.: para extrair múltiplos campos):

- Master item: HTTP Agent → `GET /zabbix/cam5000/total`
- Dependent item para a contagem:
  1. **JSON Path:** `$.total`
  2. **Simple change**

### Por IP de origem (diagnóstico / múltiplas portas)

`/zabbix/ip/{ip}/total` (JSON) é útil para diagnosticar quando várias
câmeras chegam com o mesmo IP público. Para coletar várias portas em uma
chamada, configure um master item **HTTP Agent** consultando a rota JSON
e use **dependent items** com preprocessing JSONPath + Simple change.

---

## Limitações

- **Perda em crash não-graceful:** até `--persist-interval` segundos de
  contagem podem se perder (default 60 s). SIGTERM/SIGINT fazem flush
  final e não perdem nada.
- **Match no recovery é por nome:** renomear uma câmera no flag (ex:
  `cam5000` → `entrada_norte`) faz o serviço reiniciar do zero para ela
  e marcar a entrada antiga como órfã no disco.
- **Reset do contador descarta o ponto no Zabbix:** restart sem
  `state.json` válido faz `Total` voltar a zero; o preprocessing
  `Simple change` ignora o ponto. Para evitar lacuna, garanta que o
  arquivo de estado esteja preservado entre restarts.
- **Sem TLS:** coloque atrás de Nginx/Caddy se precisar de HTTPS.
- **Sem `--min-gap-ms`** nesta versão (intencional).
- **Sem LLD pronto** para Zabbix (descoberta automática) — pode ser
  evoluído.

---

## Possíveis otimizações futuras em Go

1. Usar canais Go para desacoplar leitura UDP e processamento.
2. Worker pool quando há muitas câmeras.
3. `net.ListenConfig` para opções avançadas de socket (SO_REUSEPORT etc).
4. Buffer/channel por câmera para evitar bloqueio em picos.
5. Exportar métricas Prometheus.
6. Endpoint multi-valor para Zabbix discovery / LLD.
7. LLD do Zabbix para descoberta automática dos contadores.
8. Config YAML/JSON (mantendo flags como atalho).
9. Otimização de alocação no parsing para volume muito alto.
10. Métricas por IP de origem sem comprometer a identidade por porta.
11. TLS nativo ou Nginx/Caddy na frente.
12. Match no recovery por `udp_port` (em vez de nome), tornando rename
    de câmera não-destrutivo.
