package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"os"
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
	totalLEDs  = 24 // Match your 24-LED ring size
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

func main() {
	initSerial()

	// Serve Embedded UI from templates directory
	subFS, err := fs.Sub(content, "templates")
	if err != nil {
		log.Fatal(err)
	}
	fileServer := http.FileServer(http.FS(subFS))
	http.Handle("/", fileServer)

	http.HandleFunc("/ws", handleWebSocket)
	http.HandleFunc("/api/agent/event", handleAgentEvent)

	// Background worker to handle completion timers and cleanup
	go startSessionExpirationWorker()

	log.Println("[Server] Running on http://0.0.0.0:5000")
	if err := http.ListenAndServe("0.0.0.0:5000", nil); err != nil {
		log.Fatal(err)
	}
}

// Auto-detect serial port using USB VID:PID signatures (CH340, CP2102, FTDI)
func initSerial() {
	ports, err := enumerator.GetDetailedPortsList()
	if err != nil {
		log.Printf("[Serial Warning] Could not enumerate ports: %v", err)
		serialPort = nil
		return
	}

	if len(ports) == 0 {
		log.Println("[Serial Info] No serial ports found. Running in software-only mode.")
		serialPort = nil
		return
	}

	var targetPort string

	for _, p := range ports {
		if p.IsUSB {
			vid := strings.ToUpper(p.VID)
			pid := strings.ToUpper(p.PID)
			log.Printf("[Serial Scan] Found USB Port: %s (VID:PID=%s:%s)", p.Name, vid, pid)

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

	// Ultimate fallback to first system port if no USB flag is set
	if targetPort == "" && len(ports) > 0 {
		targetPort = ports[0].Name
	}

	if targetPort == "" {
		log.Println("[Serial Info] No suitable serial port found. Running in software-only mode.")
		serialPort = nil
		return
	}

	mode := &serial.Mode{BaudRate: 115200}
	var openErr error
	serialPort, openErr = serial.Open(targetPort, mode)
	if openErr != nil {
		log.Printf("[Serial Error] Failed to open port %s: %v", targetPort, openErr)
		serialPort = nil
	} else {
		log.Printf("[Serial] Successfully connected to ESP device on auto-detected port: %s", targetPort)
	}
}

func handleAgentEvent(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var data map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
		data = make(map[string]interface{})
	}

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

	color := []int{99, 102, 241} // Default indigo
	statusText := "Started"
	isCompleted := false

	if containsAny(eventType, []string{"tool", "pre", "edit", "work", "running"}) {
		color = []int{245, 158, 11} // Amber/Gold for working
		statusText = "Working"
	} else if containsAny(eventType, []string{"complete", "stop", "end"}) {
		color = []int{16, 185, 129} // Emerald green for complete
		statusText = "Completed"
		isCompleted = true
	}

	sessionsMu.Lock()
	existing, exists := sessions[sessionID]
	var compTime time.Time
	if isCompleted {
		if exists && !existing.CompletedAt.IsZero() {
			compTime = existing.CompletedAt
		} else {
			compTime = time.Now()
		}
	}

	sessions[sessionID] = SessionEvent{
		Source:      source,
		EventType:   eventType,
		StatusText:  statusText,
		Color:       color,
		Timestamp:   time.Now().Format("15:04:05"),
		SessionID:   sessionID,
		LastSeen:    time.Now(),
		CompletedAt: compTime,
	}
	sessionsMu.Unlock()

	payload := generateLEDPayload()
	broadcastWebSocket(sessions[sessionID])
	sendToSerial(payload)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{"status": "success"})
}

// Background worker: Waits 30 seconds after completion, removes sector, and re-divides LEDs
func startSessionExpirationWorker() {
	ticker := time.NewTicker(1 * time.Second)
	for range ticker.C {
		sessionsMu.Lock()
		now := time.Now()
		modified := false

		for id, sess := range sessions {
			if now.Sub(sess.LastSeen) > 30*time.Minute {
				delete(sessions, id)
				modified = true
			} else if !sess.CompletedAt.IsZero() && now.Sub(sess.CompletedAt) > 30*time.Second {
				delete(sessions, id)
				modified = true
			}
		}
		sessionsMu.Unlock()

		if modified {
			payload := generateLEDPayload()
			sendToSerial(payload)
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

	numSessions := len(activeList)
	var segments []Segment

	if numSessions == 0 {
		segments = append(segments, Segment{
			Start:     0,
			End:       totalLEDs - 1,
			Color:     []int{0, 100, 150},
			DotColor:  []int{255, 255, 255},
			Animation: "breathing",
		})
	} else {
		ledsPerSession := max(1, totalLEDs/numSessions)
		for i, sess := range activeList {
			start := i * ledsPerSession
			end := start + ledsPerSession - 1
			if i == numSessions-1 {
				end = totalLEDs - 1
			}

			// Animation mappings:
			// - Working -> bounce animation with gold dot
			// - Started / Completed -> pulse animation
			anim := "solid"
			dotColor := []int{255, 255, 255}

			if sess.StatusText == "Working" {
				anim = "bounce"
				dotColor = []int{255, 220, 0}
			} else if sess.StatusText == "Started" || sess.StatusText == "Completed" {
				anim = "pulse"
			}

			segments = append(segments, Segment{
				Start:     start,
				End:       end,
				Color:     sess.Color,
				DotColor:  dotColor,
				Animation: anim,
			})
		}
	}

	return LEDPayload{TotalLEDs: totalLEDs, Segments: segments}
}

func sendToSerial(payload LEDPayload) {
	if serialPort == nil {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_, err = serialPort.Write(append(data, '\n'))
	if err != nil {
		serialPort.Close()
		serialPort = nil
	}
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
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
	}()

	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			break
		}
	}
}

func broadcastWebSocket(event SessionEvent) {
	clientsMu.Lock()
	defer clientsMu.Unlock()

	for conn := range clients {
		err := conn.WriteJSON(event)
		if err != nil {
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