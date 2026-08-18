package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
	"golang.org/x/term"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/user"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"go.bug.st/serial"
	"go.bug.st/serial/enumerator"
)

//go:embed templates/index.html
var content embed.FS

type SessionEvent struct {
	Source      string    `json:"source"`
	EventType   string    `json:"event_type"`
	StatusText  string    `json:"status_text"`
	Color       []int     `json:"color"`
	Timestamp   string    `json:"timestamp"`
	SessionID   string    `json:"session_id"`
	ToolName    string    `json:"tool_name"`
	Tools       []string  `json:"tools"`
	Toolsets    []string  `json:"toolsets"`
	Hostname    string    `json:"hostname"`
	User        string    `json:"user"`
	Removable   bool      `json:"removable"`
	RawPayload  string    `json:"raw_payload"`
	LastSeen    time.Time `json:"-"`
	CompletedAt time.Time `json:"-"`
}

type Segment struct {
	Start     int    `json:"start"`
	End       int    `json:"end"`
	Color     []int  `json:"color"`
	DotColor  []int  `json:"dotColor"`
	Animation string `json:"animation"`
}

type LEDPayload struct {
	TotalLEDs int       `json:"total_leds"`
	Segments  []Segment `json:"segments"`
}

var (
	sessions   = make(map[string]SessionEvent)
	sessionsMu sync.Mutex
	clients    = make(map[*websocket.Conn]bool)
	clientsMu  sync.Mutex
	serialPort serial.Port
	serialMu   sync.Mutex
	serialInited bool
	totalLEDs  = 24 // Match your 24-LED ring size
)

var colorSets = []struct {
	Color    []int
	DotColor []int
}{
	{Color: []int{99, 102, 241}, DotColor: []int{255, 220, 0}},  // Indigo + Yellow
	{Color: []int{34, 197, 94}, DotColor: []int{255, 255, 255}},  // Green + White
	{Color: []int{137, 109, 255}, DotColor: []int{255, 220, 0}}, // Violet + Yellow
	{Color: []int{6, 230, 191}, DotColor: []int{255, 220, 0}},   // Teal + Yellow
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

var remoteAddr = flag.String("remote", "", "Remote SSH host:port to establish reverse tunnel (e.g. 192.168.1.50:5000)")

func main() {
	log.Println("[Server] Starting...")
	flag.Parse()

	if *remoteAddr != "" {
		go startSSHTunnel(*remoteAddr)
	}

	// Serve Embedded UI from templates directory
	subFS, err := fs.Sub(content, "templates")
	if err != nil {
		log.Fatal(err)
	}
	fileServer := http.FileServer(http.FS(subFS))
	http.Handle("/", fileServer)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
	})
	http.HandleFunc("/ws", handleWebSocket)
	http.Handle("/api/agent/event", http.TimeoutHandler(http.HandlerFunc(handleAgentEvent), 5*time.Second, `{"status":"timeout"}`))

	// Background worker to handle completion timers and cleanup
	go startSessionExpirationWorker()

	// Serial init
	initSerial()
	sendToSerial(generateLEDPayload())

	log.Println("[Server] Running on http://0.0.0.0:5000")
	if err := http.ListenAndServe("0.0.0.0:5000", nil); err != nil {
		log.Fatalf("[Server] Failed to start: %v", err)
	}
}

// Auto-detect serial port using USB VID:PID signatures (CH340, CP2102, FTDI)
func initSerial() {
	log.Println("[Serial] initSerial started")
	serialMu.Lock()
	defer serialMu.Unlock()

	ports, err := enumerator.GetDetailedPortsList()
	if err != nil {
		log.Printf("[Serial] GetDetailedPortsList error: %v", err)
		serialInited = true
		return
	}

	if len(ports) == 0 {
		log.Println("[Serial] No ports found")
		serialInited = true
		return
	}

	log.Printf("[Serial] Found %d ports", len(ports))
	var targetPort string

	for _, p := range ports {
		if p.IsUSB {
			vid := strings.ToUpper(p.VID)
			pid := strings.ToUpper(p.PID)
			log.Printf("[Serial] USB Port: %s VID:PID=%s:%s", p.Name, vid, pid)

			// Match common microcontroller USB-to-Serial bridge chips:
			// - 1A86:7523 -> CH340 (NodeMCU / generic boards)
			// - 10C4:EA60 -> CP2102 (ESP32 development boards)
			// - 0403:6001 -> FTDI chips
			if (vid == "1A86" && pid == "7523") ||
			   (vid == "10C4" && pid == "EA60") ||
			   (vid == "0403" && pid == "6001") {
				targetPort = p.Name
				break
			}
		}
	}

	// Fallback to the first available USB port if specific chip VID:PID isn't matched
	if targetPort == "" {
		for _, p := range ports {
			if p.IsUSB {
				targetPort = p.Name
				break
			}
		}
	}

//	// Ultimate fallback to first system port if no USB flag is set
//	if targetPort == "" && len(ports) > 0 {
//		targetPort = ports[0].Name
//	}
//
	if targetPort == "" {
		log.Println("[Serial] No suitable port found")
		serialInited = true
		return
	}

	log.Printf("[Serial] Trying to open port: %s", targetPort)
	mode := &serial.Mode{BaudRate: 115200}
	serialPort, err = serial.Open(targetPort, mode)
	if err != nil {
		log.Printf("[Serial] Open failed: %v", err)
		serialPort = nil
	} else {
		log.Printf("[Serial] Successfully opened: %s", targetPort)
	}
	serialInited = true
	log.Println("[Serial] initSerial finished")
}

func handleAgentEvent(w http.ResponseWriter, r *http.Request) {
	log.Printf("[HTTP] Received %s %s from %s", r.Method, r.URL.Path, r.RemoteAddr)

	if r.Method != http.MethodPost {
		log.Printf("[HTTP] Method not allowed: %s", r.Method)
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	log.Printf("[HTTP] Decoding JSON body...")
	rawBody, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("[HTTP] Body read error: %v", err)
	}
	r.Body = io.NopCloser(bytes.NewReader(rawBody))
	rawPayload := strings.TrimSpace(string(rawBody))

	var data map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
		log.Printf("[HTTP] JSON decode error: %v", err)
		data = make(map[string]interface{})
	}
	log.Printf("[HTTP] Payload: %+v", data)

	sessionID, _ := data["session_id"].(string)
	if sessionID == "" {
		sessionID = "default-session"
	}
	source, _ := data["source"].(string)
	if source == "" {
		source = "unknown"
	}
	eventType, _ := data["event_type"].(string)
	if eventType == "" {
		eventType = "unknown"
	}
	toolName, _ := data["tool_name"].(string)
	if toolName == "" {
		toolName = "unknown"
	}

	var tools []string
	if t, ok := data["tools"].([]interface{}); ok {
		for _, v := range t {
			if s, ok := v.(string); ok && s != "" {
				tools = append(tools, s)
			}
		}
	}
	if len(tools) == 0 {
		tools = []string{"unknown"}
	}

	var toolsets []string
	if t, ok := data["toolsets"].([]interface{}); ok {
		for _, v := range t {
			if s, ok := v.(string); ok && s != "" {
				toolsets = append(toolsets, s)
			}
		}
	}
	if len(toolsets) == 0 {
		toolsets = []string{"unknown"}
	}

	hostname, _ := data["hostname"].(string)
	if hostname == "" {
		hostname = "unknown"
	}
	user, _ := data["user"].(string)
	if user == "" {
		user = "unknown"
	}

	color := []int{99, 102, 241} // Default indigo
	statusText := "Started"
	isCompleted := false

	if containsAny(eventType, []string{"tool", "pre", "edit", "work", "running"}) {
		color = []int{34, 197, 94} // Green for working
		statusText = "Working"
	} else if containsAny(eventType, []string{"complete", "stop", "end"}) {
		color = []int{16, 185, 129} // Emerald green for complete
		statusText = "Completed"
		isCompleted = true
	}

	sessionsMu.Lock()
	existing, exists := sessions[sessionID]

	// If session was idle, reset to working on new activity
	if exists && existing.StatusText == "Idle" {
		if containsAny(eventType, []string{"tool", "pre", "edit", "work", "running"}) {
			color = []int{34, 197, 94} // Green for working
			statusText = "Working"
		}
	}
	var compTime time.Time
	if isCompleted {
		if exists && !existing.CompletedAt.IsZero() {
			compTime = existing.CompletedAt
		} else {
			compTime = time.Now()
		}
	}

	removable := isCompleted
	if exists {
		removable = removable || existing.Removable
	}

	sessions[sessionID] = SessionEvent{
		Source:      source,
		EventType:   eventType,
		StatusText:  statusText,
		Color:       color,
		Timestamp:   time.Now().Format("15:04:05"),
		SessionID:   sessionID,
		ToolName:    toolName,
		Tools:       tools,
		Toolsets:    toolsets,
		Hostname:    hostname,
		User:        user,
		Removable:   removable,
		RawPayload:  rawPayload,
		LastSeen:    time.Now(),
		CompletedAt: compTime,
	}
	sessionsMu.Unlock()

	// Write response FIRST before any async work
	w.Header().Set("Content-Type", "application/json")
	log.Printf("[HTTP] Writing immediate response")
	if err := json.NewEncoder(w).Encode(map[string]interface{}{"status": "success"}); err != nil {
		log.Printf("[HTTP] Response write error: %v", err)
	}
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
	log.Printf("[HTTP] Immediate response sent")

	// Async work after response
	payload := generateLEDPayload()
	log.Printf("[HTTP] Broadcasting WebSocket and sending serial payload")
	go broadcastWebSocket(sessions[sessionID])
	go sendToSerial(payload)
}

// Background worker: Marks sessions idle after 20 seconds of inactivity,
// and removes them entirely after 2 minutes if completed or idle.
func startSessionExpirationWorker() {
	ticker := time.NewTicker(1 * time.Second)
	for range ticker.C {
		sessionsMu.Lock()
		now := time.Now()
		modified := false
		var updatedSessions []SessionEvent
		var removedIDs []string

		for id, sess := range sessions {
			// Mark working sessions as idle after 20 seconds of inactivity
			if sess.StatusText == "Working" && !sess.LastSeen.IsZero() && now.Sub(sess.LastSeen) > 20*time.Second {
				sess.StatusText = "Idle"
				sess.Color = []int{245, 158, 11} // Orange for idle
				sessions[id] = sess
				updatedSessions = append(updatedSessions, sess)
				modified = true
			}

			// Remove entirely after 2 minutes if completed or idle
			if (sess.StatusText == "Completed" || sess.StatusText == "Idle") && !sess.LastSeen.IsZero() && now.Sub(sess.LastSeen) > 1*time.Minute {
				delete(sessions, id)
				removedIDs = append(removedIDs, id)
				modified = true
			}
		}
		sessionsMu.Unlock()

		if modified {
			payload := generateLEDPayload()
			sendToSerial(payload)
			for _, sess := range updatedSessions {
				go broadcastWebSocket(sess)
			}
			for _, id := range removedIDs {
				go broadcastRemoval(id)
			}
		}
	}
}

func generateLEDPayload() LEDPayload {
	sessionsMu.Lock()
	defer sessionsMu.Unlock()

	var activeList []SessionEvent
	for _, sess := range sessions {
		activeList = append(activeList, sess)
	}

	if len(activeList) == 0 {
		return LEDPayload{
			TotalLEDs: totalLEDs,
			Segments: []Segment{{
				Start:     0,
				End:       0,
				Color:     []int{144, 238, 144},
				DotColor:  []int{144, 238, 144},
				Animation: "pulse",
			}},
		}
	}

	sort.Slice(activeList, func(i, j int) bool {
		return activeList[i].LastSeen.Before(activeList[j].LastSeen)
	})

	var segments []Segment
	ledsPerSession := max(1, totalLEDs/len(activeList))
	workingIdx := 0
	for i, sess := range activeList {
		start := i * ledsPerSession
		end := start + ledsPerSession - 1
		if i == len(activeList)-1 {
			end = totalLEDs - 1
		}

		var segmentColor, dotColor []int
		var animation string

		if sess.StatusText == "Working" {
			cs := colorSets[workingIdx%len(colorSets)]
			workingIdx++
			segmentColor = cs.Color
			dotColor = cs.DotColor
			animation = "bounce"
		} else if sess.StatusText == "Idle" {
			segmentColor = []int{255, 193, 113}
			dotColor = []int{255, 255, 255}
			animation = "pulse"
		} else {
			segmentColor = []int{16, 185, 129}
			dotColor = []int{255, 255, 255}
			animation = "pulse"
		}

		segments = append(segments, Segment{
			Start:     start,
			End:       end,
			Color:     segmentColor,
			DotColor:  dotColor,
			Animation: animation,
		})
	}

	return LEDPayload{TotalLEDs: totalLEDs, Segments: segments}
}

func sendToSerial(payload LEDPayload) {
	serialMu.Lock()
	if !serialInited || serialPort == nil {
		serialMu.Unlock()
		log.Println("[Serial] sendToSerial skipped: not inited or nil port")
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		serialMu.Unlock()
		log.Printf("[Serial] Marshal error: %v", err)
		return
	}
	log.Printf("[Serial] TX: %s", string(data))
	_, err = serialPort.Write(append(data, '\n'))
	if err != nil {
		log.Printf("[Serial] Write error: %v", err)
		serialPort.Close()
		serialPort = nil
	}
	serialMu.Unlock()
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[WS] Upgrade error: %v", err)
		return
	}

	clientsMu.Lock()
	clients[conn] = true
	clientsMu.Unlock()

	defer func() {
		clientsMu.Lock()
		delete(clients, conn)
		clientsMu.Unlock()
		conn.Close()
		log.Println("[WS] Client disconnected")
	}()

	// Send periodic pings to keep connection alive
	go func() {
		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			clientsMu.Lock()
			if _, ok := clients[conn]; !ok {
				clientsMu.Unlock()
				return
			}
			clientsMu.Unlock()
		if err := conn.WriteMessage(websocket.PingMessage, []byte("keepalive")); err != nil {
			return
		}
		}
	}()

	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("[WS] Read error: %v", err)
			}
			break
		}
	}
}

func broadcastWebSocket(event SessionEvent) {
	clientsMu.Lock()
	defer clientsMu.Unlock()

	count := len(clients)
	log.Printf("[WS] Broadcasting to %d clients", count)
	for conn := range clients {
		err := conn.WriteJSON(event)
		if err != nil {
			log.Printf("[WS] Write error: %v", err)
			conn.Close()
			delete(clients, conn)
		}
	}
}

func broadcastRemoval(sessionID string) {
	clientsMu.Lock()
	defer clientsMu.Unlock()

	count := len(clients)
	log.Printf("[WS] Broadcasting removal for %s to %d clients", sessionID, count)
	for conn := range clients {
		conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
		err := conn.WriteJSON(map[string]string{
			"event_type": "session_removed",
			"session_id": sessionID,
		})
		if err != nil {
			log.Printf("[WS] Write error: %v", err)
			conn.Close()
			delete(clients, conn)
		}
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(substr) == 0 || containsHelper(s, substr))
}

func containsHelper(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func containsAny(s string, subStrs []string) bool {
	for _, sub := range subStrs {
		if contains(s, sub) {
			return true
		}
	}
	return false
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func startSSHTunnel(remote string) {
	parts := strings.SplitN(remote, ":", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		log.Fatalf("[SSH] Invalid -remote format, expected host:port (got %q)", remote)
	}
	host := parts[0]
	remotePort := parts[1]

	authMethods, user, err := buildKeyAuthMethods(host)
	if err != nil {
		log.Printf("[SSH] Key auth setup failed: %v", err)
		return
	}

	if err := dialAndListen(host, remotePort, user, authMethods); err == nil {
		return
	}

	if !isAuthError(err) {
		log.Printf("[SSH] Connection failed: %v", err)
		return
	}

	log.Println("[SSH] Key auth failed; falling back to password authentication")
	pw, err := promptPassword(user, host)
	if err != nil {
		log.Printf("[SSH] Password prompt failed: %v", err)
		return
	}
	authMethods = []ssh.AuthMethod{ssh.Password(pw)}
	if err := dialAndListen(host, remotePort, user, authMethods); err != nil {
		log.Printf("[SSH] Password auth failed: %v", err)
	}
}

func dialAndListen(host, remotePort, user string, authMethods []ssh.AuthMethod) error {
	addr := host
	if !strings.Contains(addr, ":") {
		addr += ":22"
	}

	config := &ssh.ClientConfig{
		User:            user,
		Auth:            authMethods,
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         15 * time.Second,
	}

	conn, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return fmt.Errorf("ssh dial %s: %w", addr, err)
	}

	ln, err := conn.Listen("tcp", "0.0.0.0:"+remotePort)
	if err != nil {
		conn.Close()
		return fmt.Errorf("remote listen :%s: %w", remotePort, err)
	}

	log.Printf("[SSH] Reverse tunnel active: remote 0.0.0.0:%s -> localhost:5000 via %s@%s", remotePort, user, host)

	for {
		c, err := ln.Accept()
		if err != nil {
			conn.Close()
			return fmt.Errorf("accept: %w", err)
		}
		go func(rconn net.Conn) {
			defer rconn.Close()
			lconn, err := net.Dial("tcp", "localhost:5000")
			if err != nil {
				log.Printf("[SSH] local dial error: %v", err)
				return
			}
			defer lconn.Close()
			go io.Copy(lconn, rconn)
			io.Copy(rconn, lconn)
		}(c)
	}
}

func buildKeyAuthMethods(remoteHost string) ([]ssh.AuthMethod, string, error) {
	user := currentUser()
	host := remoteHost
	if idx := strings.Index(host, "@"); idx >= 0 {
		user = host[:idx]
		host = host[idx+1:]
	}

	var methods []ssh.AuthMethod

	if sock := os.Getenv("SSH_AUTH_SOCK"); sock != "" {
		if conn, err := net.Dial("unix", sock); err == nil {
			ag := agent.NewClient(conn)
			if signers, err := ag.Signers(); err == nil && len(signers) > 0 {
				methods = append(methods, ssh.PublicKeys(signers...))
			}
		}
	}

	home, err := os.UserHomeDir()
	if err != nil {
		home = os.Getenv("HOME")
	}
	keyPaths := []string{
		home + "/.ssh/id_ed25519",
		home + "/.ssh/id_ecdsa",
		home + "/.ssh/id_rsa",
	}
	for _, p := range keyPaths {
		if data, err := os.ReadFile(p); err == nil {
			if signer, err := ssh.ParsePrivateKey(data); err == nil {
				methods = append(methods, ssh.PublicKeys(signer))
			}
		}
	}

	return methods, user, nil
}

func currentUser() string {
	u, err := user.Current()
	if err != nil || u == nil || u.Username == "" {
		if h := os.Getenv("USER"); h != "" {
			return h
		}
		if h := os.Getenv("USERNAME"); h != "" {
			return h
		}
		return "root"
	}
	return u.Username
}

func promptPassword(user, host string) (string, error) {
	fmt.Fprintf(os.Stderr, "Password for %s@%s: ", user, host)
	pw, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", err
	}
	return string(pw), nil
}

func isAuthError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "permission denied") ||
		strings.Contains(msg, "authentication failed") ||
		strings.Contains(msg, "no supported authentication methods") ||
		strings.Contains(msg, "too many authentication failures") ||
		strings.Contains(msg, "auth fail")
}
