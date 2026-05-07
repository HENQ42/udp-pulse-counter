// contador_udp_zabbix.go
//
// Contador de veiculos a partir de pulsos UDP (Pumatronix/ITSCAM ou similares).
//
// - Multiplos listeners UDP, um por camera/porta.
// - Conta por borda inativo->ativo (transicao).
// - Agrupa por bucket temporal (default 60s).
// - Mantem em RAM apenas: bucket atual + ultimo bucket fechado.
// - Expoe rotas HTTP GET para Zabbix consultar.
// - Suporta token de autorizacao por flag.
// - Suporta consulta por IP de origem (lista todas as portas onde aquele IP apareceu).
//
// Build: go build -o contador_udp_zabbix contador_udp_zabbix.go
// Run:   ./contador_udp_zabbix --port-range 5001-5005 --http-port 8080
package main

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ----------------------------------------------------------------------------
// Tipos de configuracao e flags
// ----------------------------------------------------------------------------

type stringSliceFlag []string

func (s *stringSliceFlag) String() string     { return strings.Join(*s, ",") }
func (s *stringSliceFlag) Set(v string) error { *s = append(*s, v); return nil }

type cameraSpec struct {
	Name string
	Port int
}

type config struct {
	HTTPHost      string
	HTTPPort      int
	UDPHost       string
	BucketSeconds int
	ActiveMode    string // high|low
	AuthToken     string
	AllowedCIDRs  []*net.IPNet
	Debug         bool
	Cameras       []cameraSpec
	MaxSourceIPs  int // limite por contador
}

// ----------------------------------------------------------------------------
// Counter
// ----------------------------------------------------------------------------

type Counter struct {
	mu sync.RWMutex

	Name          string
	UDPPort       int
	BucketSeconds int64

	// bucket atual
	CurrentBucketStart int64
	CurrentCount       int64

	// ultimo bucket fechado
	LastBucketStart int64
	LastBucketEnd   int64
	LastCount       int64

	// totais e estado
	Total           int64
	PacketsReceived int64
	PacketsIgnored  int64

	LastPacketAt time.Time
	LastEventAt  time.Time

	PreviousActive bool
	HasFirstPacket bool

	// mapa bounded de IPs de origem (somente diagnostico).
	// Tamanho maximo controlado por MaxSourceIPs. Cheio -> evict do mais antigo.
	SourceIPs    map[string]time.Time
	MaxSourceIPs int
}

func newCounter(name string, port int, bucketSeconds int64, maxSourceIPs int) *Counter {
	now := time.Now().Unix()
	bs := bucketStart(now, bucketSeconds)
	return &Counter{
		Name:               name,
		UDPPort:            port,
		BucketSeconds:      bucketSeconds,
		CurrentBucketStart: bs,
		LastBucketStart:    bs - bucketSeconds, // bucket "anterior" sintetico (count=0)
		LastBucketEnd:      bs,
		SourceIPs:          make(map[string]time.Time, maxSourceIPs),
		MaxSourceIPs:       maxSourceIPs,
	}
}

// touchSourceIPLocked atualiza/insere um IP respeitando MaxSourceIPs.
// Quando cheio, descarta o IP com timestamp mais antigo. c.mu deve estar travado.
func (c *Counter) touchSourceIPLocked(ip string, now time.Time) {
	if _, ok := c.SourceIPs[ip]; ok {
		c.SourceIPs[ip] = now
		return
	}
	if c.MaxSourceIPs > 0 && len(c.SourceIPs) >= c.MaxSourceIPs {
		var oldestKey string
		var oldestTS time.Time
		first := true
		for k, t := range c.SourceIPs {
			if first || t.Before(oldestTS) {
				oldestKey = k
				oldestTS = t
				first = false
			}
		}
		delete(c.SourceIPs, oldestKey)
	}
	c.SourceIPs[ip] = now
}

func bucketStart(ts int64, bucketSeconds int64) int64 {
	return (ts / bucketSeconds) * bucketSeconds
}

// rotateLocked sincroniza o estado temporal.
// Se ja saimos do CurrentBucketStart, fecha-o como "ultimo bucket" e
// avanca para o bucket atual. Buckets vazios intermediarios sao
// representados pelo proprio "ultimo bucket fechado" sendo o imediatamente
// anterior ao bucket atual com count=0.
func (c *Counter) rotateLocked(now int64) {
	bs := bucketStart(now, c.BucketSeconds)
	if bs == c.CurrentBucketStart {
		return
	}
	// Bucket atual virou bucket fechado.
	if bs == c.CurrentBucketStart+c.BucketSeconds {
		// avancou exatamente 1 bucket
		c.LastBucketStart = c.CurrentBucketStart
		c.LastBucketEnd = c.CurrentBucketStart + c.BucketSeconds
		c.LastCount = c.CurrentCount
	} else {
		// pulamos varios buckets sem trafego.
		// O ultimo bucket fechado deve ser o imediatamente anterior ao atual,
		// com contagem 0 (nao houve eventos).
		c.LastBucketStart = bs - c.BucketSeconds
		c.LastBucketEnd = bs
		c.LastCount = 0
		// Observacao: o proprio CurrentCount pertencia a um bucket antigo,
		// mas ja eh historico nao consultavel nesta versao.
	}
	c.CurrentBucketStart = bs
	c.CurrentCount = 0
}

// SyncTime garante que o counter esteja com bucket atualizado.
// Pode ser chamado antes de qualquer leitura ou escrita.
func (c *Counter) SyncTime() {
	c.mu.Lock()
	c.rotateLocked(time.Now().Unix())
	c.mu.Unlock()
}

// ----------------------------------------------------------------------------
// Parsing dos pacotes UDP
// ----------------------------------------------------------------------------

// parsePulsePayload tenta interpretar o payload como um valor de pulso.
// Retorna 0 ou 1 e ok=true se conseguiu interpretar.
func parsePulsePayload(data []byte) (int, bool) {
	if len(data) == 0 {
		return 0, false
	}
	// 1) Tentar texto.
	s := strings.TrimSpace(strings.ToLower(string(data)))
	switch s {
	case "1", "true", "ativo", "active", "high", "alto":
		return 1, true
	case "0", "false", "inativo", "inactive", "low", "baixo":
		return 0, true
	}
	// 2) Tentar binario big-endian de 1, 2, 4, 8 bytes.
	switch len(data) {
	case 1:
		if data[0] != 0 {
			return 1, true
		}
		return 0, true
	case 2:
		if binary.BigEndian.Uint16(data) != 0 {
			return 1, true
		}
		return 0, true
	case 4:
		if binary.BigEndian.Uint32(data) != 0 {
			return 1, true
		}
		return 0, true
	case 8:
		if binary.BigEndian.Uint64(data) != 0 {
			return 1, true
		}
		return 0, true
	}
	// 3) Fallback: qualquer byte diferente de zero -> ativo.
	for _, b := range data {
		if b != 0 {
			return 1, true
		}
	}
	return 0, true
}

// ----------------------------------------------------------------------------
// UDP listener
// ----------------------------------------------------------------------------

func runUDPListener(cfg *config, c *Counter) error {
	addr := &net.UDPAddr{IP: net.ParseIP(cfg.UDPHost), Port: c.UDPPort}
	if addr.IP == nil {
		addr.IP = net.IPv4zero
	}
	pc, err := net.ListenUDP("udp", addr)
	if err != nil {
		return fmt.Errorf("UDP %s:%d: %w", cfg.UDPHost, c.UDPPort, err)
	}
	log.Printf("[UDP] camera=%s listening on %s:%d", c.Name, cfg.UDPHost, c.UDPPort)

	go func() {
		// Buffer fixo reutilizado: nao alocamos por pacote.
		// handlePacket roda sincronamente nesta goroutine, entao buf[:n]
		// pode ser usado direto sem corrida.
		buf := make([]byte, 2048)

		// Loop com recover por iteracao: um panic no processamento de UM pacote
		// nao derruba o listener (e nao derruba o processo inteiro).
		// O socket UDP eh preservado entre iteracoes.
		for {
			func() {
				defer func() {
					if r := recover(); r != nil {
						log.Printf("[UDP] camera=%s PANIC recuperado: %v\n%s",
							c.Name, r, debug.Stack())
					}
				}()
				n, src, err := pc.ReadFromUDP(buf)
				if err != nil {
					log.Printf("[UDP] camera=%s read error: %v", c.Name, err)
					return
				}
				handlePacket(cfg, c, buf[:n], src)
			}()
		}
	}()
	return nil
}

func sourceAllowed(cfg *config, ip net.IP) bool {
	if len(cfg.AllowedCIDRs) == 0 {
		return true
	}
	for _, cidr := range cfg.AllowedCIDRs {
		if cidr.Contains(ip) {
			return true
		}
	}
	return false
}

func handlePacket(cfg *config, c *Counter, data []byte, src *net.UDPAddr) {
	now := time.Now()
	srcIP := src.IP.String()

	if !sourceAllowed(cfg, src.IP) {
		if cfg.Debug {
			log.Printf("[UDP] camera=%s port=%d src=%s status=IGNORED_SOURCE_CIDR",
				c.Name, c.UDPPort, src.String())
		}
		c.mu.Lock()
		defer c.mu.Unlock()
		c.PacketsIgnored++
		return
	}

	val, ok := parsePulsePayload(data)
	if !ok {
		if cfg.Debug {
			log.Printf("[UDP] camera=%s port=%d src=%s hex=%q status=IGNORED_UNPARSEABLE",
				c.Name, c.UDPPort, src.String(), hex.EncodeToString(data))
		}
		c.mu.Lock()
		defer c.mu.Unlock()
		c.PacketsReceived++
		c.PacketsIgnored++
		c.LastPacketAt = now
		c.touchSourceIPLocked(srcIP, now)
		return
	}

	// Determinar "active" levando em conta active_mode.
	rawActive := val == 1
	active := rawActive
	if cfg.ActiveMode == "low" {
		active = !rawActive
	}

	// Secao critica isolada em closure com defer Unlock:
	// se houver panic aqui dentro, o mutex e liberado antes do panic propagar
	// para o recover() do listener.
	status := func() string {
		c.mu.Lock()
		defer c.mu.Unlock()

		c.rotateLocked(now.Unix())
		c.PacketsReceived++
		c.LastPacketAt = now
		c.touchSourceIPLocked(srcIP, now)

		if !c.HasFirstPacket {
			// Apenas sincroniza estado anterior, nao conta.
			c.PreviousActive = active
			c.HasFirstPacket = true
			return "FIRST_PACKET_SYNC"
		}

		var s string
		if active && !c.PreviousActive {
			c.CurrentCount++
			c.Total++
			c.LastEventAt = now
			s = "COUNTED"
		} else if active && c.PreviousActive {
			s = "IGNORED_SAME_PULSE"
		} else {
			s = "INACTIVE"
		}
		c.PreviousActive = active
		return s
	}()

	if cfg.Debug {
		log.Printf("[UDP] camera=%s port=%d src=%s hex=%q val=%d active=%v status=%s",
			c.Name, c.UDPPort, src.String(), hex.EncodeToString(data), val, active, status)
	}
}

// ----------------------------------------------------------------------------
// HTTP server
// ----------------------------------------------------------------------------

type server struct {
	cfg      *config
	counters map[string]*Counter // por nome
	byPort   map[int]*Counter    // por porta
}

func newServer(cfg *config, counters []*Counter) *server {
	s := &server{
		cfg:      cfg,
		counters: map[string]*Counter{},
		byPort:   map[int]*Counter{},
	}
	for _, c := range counters {
		s.counters[c.Name] = c
		s.byPort[c.UDPPort] = c
	}
	return s
}

func (s *server) checkAuth(r *http.Request) bool {
	if s.cfg.AuthToken == "" {
		return true
	}
	if v := r.Header.Get("Authorization"); v != "" {
		if strings.HasPrefix(v, "Bearer ") && strings.TrimPrefix(v, "Bearer ") == s.cfg.AuthToken {
			return true
		}
	}
	if v := r.Header.Get("X-Auth-Token"); v != "" && v == s.cfg.AuthToken {
		return true
	}
	if v := r.URL.Query().Get("token"); v != "" && v == s.cfg.AuthToken {
		return true
	}
	return false
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeText(w http.ResponseWriter, status int, body string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(body))
}

func unauthorized(w http.ResponseWriter) {
	writeJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "unauthorized"})
}

func fmtTS(ts int64) string {
	if ts <= 0 {
		return ""
	}
	return time.Unix(ts, 0).Format("2006-01-02T15:04:05")
}

// snapshotLast retorna os campos do ultimo bucket fechado de um counter.
func snapshotLast(c *Counter) map[string]any {
	c.mu.Lock()
	c.rotateLocked(time.Now().Unix())
	out := map[string]any{
		"camera":           c.Name,
		"udp_port":         c.UDPPort,
		"bucket_seconds":   c.BucketSeconds,
		"bucket_start_ts":  c.LastBucketStart,
		"bucket_end_ts":    c.LastBucketEnd,
		"bucket_start":     fmtTS(c.LastBucketStart),
		"bucket_end":       fmtTS(c.LastBucketEnd),
		"count":            c.LastCount,
		"total":            c.Total,
		"packets_received": c.PacketsReceived,
	}
	if !c.LastPacketAt.IsZero() {
		out["last_seen"] = c.LastPacketAt.Format("2006-01-02T15:04:05")
	}
	c.mu.Unlock()
	return out
}

// ----------------------------------------------------------------------------
// Handlers
// ----------------------------------------------------------------------------

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if !s.checkAuth(r) {
		unauthorized(w)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *server) handleIdentity(w http.ResponseWriter, r *http.Request) {
	if !s.checkAuth(r) {
		unauthorized(w)
		return
	}
	cams := []map[string]any{}
	for _, c := range s.counters {
		cams = append(cams, map[string]any{
			"name":     c.Name,
			"udp_port": c.UDPPort,
		})
	}
	sort.Slice(cams, func(i, j int) bool {
		return cams[i]["udp_port"].(int) < cams[j]["udp_port"].(int)
	})
	cidrs := []string{}
	for _, c := range s.cfg.AllowedCIDRs {
		cidrs = append(cidrs, c.String())
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                   true,
		"http_host":            s.cfg.HTTPHost,
		"http_port":            s.cfg.HTTPPort,
		"udp_host":             s.cfg.UDPHost,
		"bucket_seconds":       s.cfg.BucketSeconds,
		"active_mode":          s.cfg.ActiveMode,
		"auth_enabled":         s.cfg.AuthToken != "",
		"allowed_source_cidrs": cidrs,
		"cameras":              cams,
	})
}

func (s *server) handleCameras(w http.ResponseWriter, r *http.Request) {
	if !s.checkAuth(r) {
		unauthorized(w)
		return
	}
	cams := []map[string]any{}
	for _, c := range s.counters {
		cams = append(cams, map[string]any{
			"name":     c.Name,
			"udp_port": c.UDPPort,
		})
	}
	sort.Slice(cams, func(i, j int) bool {
		return cams[i]["udp_port"].(int) < cams[j]["udp_port"].(int)
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "cameras": cams})
}

// /zabbix/{camera}/last  e /zabbix/{camera}/last/value
// /zabbix/ip/{ip}/last   e /zabbix/ip/{ip}/last/value
func (s *server) handleZabbix(w http.ResponseWriter, r *http.Request) {
	if !s.checkAuth(r) {
		unauthorized(w)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/zabbix/")
	parts := strings.Split(path, "/")
	if len(parts) < 2 {
		http.NotFound(w, r)
		return
	}

	if parts[0] == "ip" {
		// /zabbix/ip/{ip}/last [/value]
		if len(parts) < 3 || parts[2] != "last" {
			http.NotFound(w, r)
			return
		}
		ipStr := parts[1]
		if net.ParseIP(ipStr) == nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "invalid ip"})
			return
		}
		valueOnly := len(parts) >= 4 && parts[3] == "value"
		s.handleIPLast(w, ipStr, valueOnly)
		return
	}

	// /zabbix/{camera}/last [/value]
	camName := parts[0]
	if parts[1] != "last" {
		http.NotFound(w, r)
		return
	}
	valueOnly := len(parts) >= 3 && parts[2] == "value"
	c, ok := s.counters[camName]
	if !ok {
		if valueOnly {
			writeText(w, http.StatusNotFound, "")
			return
		}
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "camera not found"})
		return
	}
	snap := snapshotLast(c)
	if valueOnly {
		writeText(w, http.StatusOK, strconv.FormatInt(snap["count"].(int64), 10))
		return
	}
	snap["ok"] = true
	writeJSON(w, http.StatusOK, snap)
}

func (s *server) handleIPLast(w http.ResponseWriter, ip string, valueOnly bool) {
	matches := []map[string]any{}
	// percorre todos counters; cada counter tem sua propria lista de SourceIPs vistos
	for _, c := range s.counters {
		c.mu.RLock()
		_, seen := c.SourceIPs[ip]
		c.mu.RUnlock()
		if !seen {
			continue
		}
		snap := snapshotLast(c)
		matches = append(matches, snap)
	}
	sort.Slice(matches, func(i, j int) bool {
		return matches[i]["udp_port"].(int) < matches[j]["udp_port"].(int)
	})

	if valueOnly {
		var sb strings.Builder
		for _, m := range matches {
			sb.WriteString(strconv.Itoa(m["udp_port"].(int)))
			sb.WriteString("=")
			sb.WriteString(strconv.FormatInt(m["count"].(int64), 10))
			sb.WriteString("\n")
		}
		writeText(w, http.StatusOK, sb.String())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":             true,
		"source_ip":      ip,
		"bucket_seconds": s.cfg.BucketSeconds,
		"matches":        matches,
	})
}

func (s *server) handleDebug(w http.ResponseWriter, r *http.Request) {
	if !s.checkAuth(r) {
		unauthorized(w)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/debug")
	path = strings.TrimPrefix(path, "/")
	if path == "" {
		all := []map[string]any{}
		for _, c := range s.counters {
			all = append(all, debugSnapshot(c))
		}
		sort.Slice(all, func(i, j int) bool {
			return all[i]["udp_port"].(int) < all[j]["udp_port"].(int)
		})
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "counters": all})
		return
	}
	c, ok := s.counters[path]
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "camera not found"})
		return
	}
	writeJSON(w, http.StatusOK, debugSnapshot(c))
}

func debugSnapshot(c *Counter) map[string]any {
	c.mu.Lock()
	c.rotateLocked(time.Now().Unix())
	ips := map[string]string{}
	for ip, t := range c.SourceIPs {
		ips[ip] = t.Format("2006-01-02T15:04:05")
	}
	out := map[string]any{
		"name":                 c.Name,
		"udp_port":             c.UDPPort,
		"bucket_seconds":       c.BucketSeconds,
		"current_bucket_start": fmtTS(c.CurrentBucketStart),
		"current_count":        c.CurrentCount,
		"last_bucket_start":    fmtTS(c.LastBucketStart),
		"last_bucket_end":      fmtTS(c.LastBucketEnd),
		"last_count":           c.LastCount,
		"total":                c.Total,
		"packets_received":     c.PacketsReceived,
		"packets_ignored":      c.PacketsIgnored,
		"previous_active":      c.PreviousActive,
		"has_first_packet":     c.HasFirstPacket,
		"source_ips":           ips,
	}
	if !c.LastPacketAt.IsZero() {
		out["last_packet_at"] = c.LastPacketAt.Format("2006-01-02T15:04:05")
	}
	if !c.LastEventAt.IsZero() {
		out["last_event_at"] = c.LastEventAt.Format("2006-01-02T15:04:05")
	}
	c.mu.Unlock()
	return out
}

// ----------------------------------------------------------------------------
// Parsing das flags
// ----------------------------------------------------------------------------

func parseCameras(specs []string) ([]cameraSpec, error) {
	out := []cameraSpec{}
	for _, s := range specs {
		parts := strings.SplitN(s, ":", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("formato invalido em --camera %q (esperado nome:porta)", s)
		}
		name := strings.TrimSpace(parts[0])
		if name == "" {
			return nil, fmt.Errorf("nome de camera vazio em %q", s)
		}
		port, err := strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || port <= 0 || port > 65535 {
			return nil, fmt.Errorf("porta invalida em --camera %q", s)
		}
		out = append(out, cameraSpec{Name: name, Port: port})
	}
	return out, nil
}

func parsePortRange(s, prefix string) ([]cameraSpec, error) {
	if s == "" {
		return nil, nil
	}
	parts := strings.SplitN(s, "-", 2)
	if len(parts) != 2 {
		return nil, fmt.Errorf("formato invalido em --port-range %q (esperado inicio-fim)", s)
	}
	start, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
	end, err2 := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err1 != nil || err2 != nil || start <= 0 || end <= 0 || start > 65535 || end > 65535 || start > end {
		return nil, fmt.Errorf("range invalido em --port-range %q", s)
	}
	out := []cameraSpec{}
	for p := start; p <= end; p++ {
		out = append(out, cameraSpec{Name: fmt.Sprintf("%s%d", prefix, p), Port: p})
	}
	return out, nil
}

func parseCIDRs(specs []string) ([]*net.IPNet, error) {
	out := []*net.IPNet{}
	for _, s := range specs {
		_, n, err := net.ParseCIDR(strings.TrimSpace(s))
		if err != nil {
			return nil, fmt.Errorf("CIDR invalido %q: %w", s, err)
		}
		out = append(out, n)
	}
	return out, nil
}

func validateCameras(cams []cameraSpec) error {
	names := map[string]bool{}
	ports := map[int]bool{}
	for _, c := range cams {
		if names[c.Name] {
			return fmt.Errorf("camera duplicada: %s", c.Name)
		}
		if ports[c.Port] {
			return fmt.Errorf("porta UDP duplicada: %d", c.Port)
		}
		names[c.Name] = true
		ports[c.Port] = true
	}
	return nil
}

// ----------------------------------------------------------------------------
// main
// ----------------------------------------------------------------------------

func main() {
	var (
		cameraFlags stringSliceFlag
		cidrFlags   stringSliceFlag
		portRange   string
		prefix      string
	)

	httpHost := flag.String("http-host", "0.0.0.0", "IP de bind do servidor HTTP")
	httpPort := flag.Int("http-port", 23187, "porta HTTP")
	udpHost := flag.String("udp-host", "0.0.0.0", "IP de bind dos listeners UDP")
	bucketSeconds := flag.Int("bucket-seconds", 60, "tamanho do periodo de agrupamento em segundos")
	active := flag.String("active", "high", "modo do estado ativo: high|low")
	authToken := flag.String("auth-token", "", "token de autorizacao para rotas HTTP (vazio = sem auth)")
	debug := flag.Bool("debug", false, "logs detalhados de cada pacote UDP")
	maxSourceIPs := flag.Int("max-source-ips", 64, "limite de IPs de origem rastreados por contador (eviction do mais antigo)")

	flag.Var(&cameraFlags, "camera", "camera no formato nome:porta (pode repetir)")
	flag.Var(&cidrFlags, "allowed-source-cidr", "CIDR permitido como origem UDP (pode repetir)")
	flag.StringVar(&portRange, "port-range", "", "range de portas inicio-fim (ex: 5001-5005)")
	flag.StringVar(&prefix, "counter-prefix", "cam", "prefixo dos nomes gerados pelo --port-range")

	flag.Parse()

	if *bucketSeconds <= 0 {
		fatal("bucket-seconds deve ser > 0")
	}
	if *maxSourceIPs <= 0 {
		fatal("max-source-ips deve ser > 0")
	}
	if *active != "high" && *active != "low" {
		fatal("active deve ser high ou low")
	}

	cams, err := parseCameras(cameraFlags)
	if err != nil {
		fatal(err.Error())
	}
	rangeCams, err := parsePortRange(portRange, prefix)
	if err != nil {
		fatal(err.Error())
	}
	cams = append(cams, rangeCams...)
	if len(cams) == 0 {
		fatal("nenhuma camera definida (use --camera ou --port-range)")
	}
	if err := validateCameras(cams); err != nil {
		fatal(err.Error())
	}

	cidrs, err := parseCIDRs(cidrFlags)
	if err != nil {
		fatal(err.Error())
	}

	cfg := &config{
		HTTPHost:      *httpHost,
		HTTPPort:      *httpPort,
		UDPHost:       *udpHost,
		BucketSeconds: *bucketSeconds,
		ActiveMode:    *active,
		AuthToken:     *authToken,
		AllowedCIDRs:  cidrs,
		Debug:         *debug,
		Cameras:       cams,
		MaxSourceIPs:  *maxSourceIPs,
	}

	log.Printf("[CFG] bucket_seconds=%d active=%s auth_enabled=%v", cfg.BucketSeconds, cfg.ActiveMode, cfg.AuthToken != "")
	if portRange != "" {
		log.Printf("[CFG] port_range=%s counter_prefix=%s", portRange, prefix)
	}

	counters := []*Counter{}
	for _, cs := range cams {
		c := newCounter(cs.Name, cs.Port, int64(cfg.BucketSeconds), cfg.MaxSourceIPs)
		counters = append(counters, c)
		if err := runUDPListener(cfg, c); err != nil {
			fatal(err.Error())
		}
	}

	srv := newServer(cfg, counters)
	mux := http.NewServeMux()
	mux.HandleFunc("/health", srv.handleHealth)
	mux.HandleFunc("/identity", srv.handleIdentity)
	mux.HandleFunc("/cameras", srv.handleCameras)
	mux.HandleFunc("/zabbix/", srv.handleZabbix)
	mux.HandleFunc("/debug", srv.handleDebug)
	mux.HandleFunc("/debug/", srv.handleDebug)

	addr := fmt.Sprintf("%s:%d", cfg.HTTPHost, cfg.HTTPPort)
	log.Printf("[HTTP] Listening on %s", addr)
	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	if err := httpSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fatal(err.Error())
	}
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, "ERRO: "+msg)
	os.Exit(1)
}
