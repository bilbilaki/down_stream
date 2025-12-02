package streamproxy

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
)

// RangeManager tracks downloaded byte ranges (the "brain")
type RangeManager struct {
	mu       sync.RWMutex
	ranges   [][2]int64 // List of [start, end] pairs
	total    int64
	filePath string
}

// NewRangeManager creates a new range tracker
func NewRangeManager(filePath string, totalSize int64) *RangeManager {
	return &RangeManager{
		ranges:   make([][2]int64, 0),
		total:    totalSize,
		filePath: filePath,
	}
}

// AddRange inserts a new range and merges overlapping/adjacent ranges
func (rm *RangeManager) AddRange(start, end int64) {
	rm.mu.Lock()
	defer rm. mu.Unlock()

	rm.ranges = append(rm.ranges, [2]int64{start, end})
	rm.mergeRanges()
}

// mergeRanges sorts and merges overlapping/adjacent intervals
func (rm *RangeManager) mergeRanges() {
	if len(rm.ranges) <= 1 {
		return
	}

	// Sort by start position
	for i := 0; i < len(rm.ranges)-1; i++ {
		for j := i + 1; j < len(rm.ranges); j++ {
			if rm.ranges[j][0] < rm.ranges[i][0] {
				rm.ranges[i], rm.ranges[j] = rm.ranges[j], rm.ranges[i]
			}
		}
	}

	merged := make([][2]int64, 0, len(rm.ranges))
	current := rm.ranges[0]

	for i := 1; i < len(rm.ranges); i++ {
		// If current range touches or overlaps with next
		if rm.ranges[i][0] <= current[1]+1 {
			// Extend current range
			if rm.ranges[i][1] > current[1] {
				current[1] = rm.ranges[i][1]
			}
		} else {
			merged = append(merged, current)
			current = rm.ranges[i]
		}
	}
	merged = append(merged, current)
	rm.ranges = merged
}

// HasRange checks if a byte position is cached
func (rm *RangeManager) HasRange(start, end int64) bool {
	rm. mu.RLock()
	defer rm.mu.RUnlock()

	for _, r := range rm.ranges {
		if start >= r[0] && end <= r[1] {
			return true
		}
	}
	return false
}

// IsComplete checks if file is fully downloaded
func (rm *RangeManager) IsComplete() bool {
	rm.mu.RLock()
	defer rm. mu.RUnlock()

	return len(rm.ranges) == 1 &&
		rm.ranges[0][0] == 0 &&
		rm.ranges[0][1] >= rm.total-1
}

// GetProgress returns download percentage
func (rm *RangeManager) GetProgress() float64 {
	rm.mu.RLock()
	defer rm.mu.RUnlock()

	var downloaded int64
	for _, r := range rm.ranges {
		downloaded += r[1] - r[0] + 1
	}
	return float64(downloaded) / float64(rm. total) * 100
}

// StreamProxy is the main proxy server
type StreamProxy struct {
	managers    map[string]*RangeManager
	managersMu  sync.RWMutex
	storageDir  string
	port        int
	server      *http.Server
}

// NewStreamProxy creates a new proxy instance
func NewStreamProxy(storageDir string, port int) *StreamProxy {
	return &StreamProxy{
		managers:   make(map[string]*RangeManager),
		storageDir: storageDir,
		port:       port,
	}
}

// Start begins the proxy server
func (sp *StreamProxy) Start() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/", sp.handleRequest)

	sp.server = &http.Server{
		Addr:    fmt.Sprintf(":%d", sp.port),
		Handler: mux,
	}

	return sp.server.ListenAndServe()
}

// parseRangeHeader parses HTTP Range header
func parseRangeHeader(header string, totalSize int64) (int64, int64) {
	if header == "" {
		return 0, totalSize - 1
	}

	// Format: bytes=start-end or bytes=start-
	header = strings.TrimPrefix(header, "bytes=")
	parts := strings.Split(header, "-")

	start, _ := strconv.ParseInt(parts[0], 10, 64)
	end := totalSize - 1

	if len(parts) > 1 && parts[1] != "" {
		end, _ = strconv.ParseInt(parts[1], 10, 64)
	}

	return start, end
}

// SparseFileWriter writes to specific positions in a sparse file
type SparseFileWriter struct {
	file     *os. File
	position int64
	mu       sync.Mutex
}

func (sfw *SparseFileWriter) Write(p []byte) (n int, err error) {
	sfw.mu.Lock()
	defer sfw.mu. Unlock()

	_, err = sfw. file. Seek(sfw.position, io.SeekStart)
	if err != nil {
		return 0, err
	}

	n, err = sfw.file.Write(p)
	sfw.position += int64(n)
	return n, err
}

// handleRequest processes incoming player requests
func (sp *StreamProxy) handleRequest(w http. ResponseWriter, r *http.Request) {
	// Extract the real URL from query param
	realURL := r.URL. Query().Get("url")
	if realURL == "" {
		http.Error(w, "Missing url parameter", http.StatusBadRequest)
		return
	}

	// Generate unique file ID from URL
	fileID := hashURL(realURL)
	localPath := fmt.Sprintf("%s/%s. video", sp.storageDir, fileID)
	metaPath := fmt. Sprintf("%s/%s.meta", sp.storageDir, fileID)

	// Get or create range manager
	sp.managersMu.Lock()
	rm, exists := sp. managers[fileID]
	if !exists {
		// First request - need to get total size
		totalSize, err := sp.getContentLength(realURL)
		if err != nil {
			sp.managersMu.Unlock()
			http.Error(w, "Failed to get content length", http.StatusBadGateway)
			return
		}

		// Create sparse file
		file, err := os. OpenFile(localPath, os.O_RDWR|os.O_CREATE, 0666)
		if err != nil {
			sp.managersMu.Unlock()
			http.Error(w, "Failed to create file", http.StatusInternalServerError)
			return
		}
		file. Truncate(totalSize) // Pre-allocate sparse file
		file.Close()

		rm = NewRangeManager(localPath, totalSize)
		sp.managers[fileID] = rm

		// Load existing metadata if available
		sp.loadMetadata(rm, metaPath)
	}
	sp.managersMu.Unlock()

	// Parse requested range
	rangeHeader := r.Header. Get("Range")
	start, end := parseRangeHeader(rangeHeader, rm. total)

	// Set response headers for partial content
	w. Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
	w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, rm. total))
	w.WriteHeader(http.StatusPartialContent) // 206! 

	// Check if we have this range cached
	if rm.HasRange(start, end) {
		// Serve from disk
		sp.serveFromDisk(w, localPath, start, end)
	} else {
		// Fetch, cache, and serve simultaneously
		sp.fetchAndServe(w, realURL, localPath, start, end, rm, metaPath)
	}
}

// serveFromDisk serves cached content
func (sp *StreamProxy) serveFromDisk(w http.ResponseWriter, path string, start, end int64) {
	file, err := os. Open(path)
	if err != nil {
		http. Error(w, "File read error", http.StatusInternalServerError)
		return
	}
	defer file.Close()

	file.Seek(start, io.SeekStart)
	io.CopyN(w, file, end-start+1)
}

// fetchAndServe downloads, caches, and streams simultaneously
func (sp *StreamProxy) fetchAndServe(w http.ResponseWriter, url, localPath string,
	start, end int64, rm *RangeManager, metaPath string) {

	// Create upstream request with Range header
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		http.Error(w, "Request creation failed", http.StatusInternalServerError)
		return
	}
	req. Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "Upstream fetch failed", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Open file for sparse write
	file, err := os.OpenFile(localPath, os.O_RDWR, 0666)
	if err != nil {
		http. Error(w, "File open failed", http.StatusInternalServerError)
		return
	}
	defer file. Close()

	// Create sparse file writer starting at 'start' position
	sparseWriter := &SparseFileWriter{
		file:     file,
		position: start,
	}

	// THE MAGIC: TeeReader
	// Everything read from upstream is ALSO written to disk
	teeReader := io. TeeReader(resp.Body, sparseWriter)

	// Stream to player while writing to disk
	written, err := io.Copy(w, teeReader)

	if err == nil && written > 0 {
		// Update metadata
		rm. AddRange(start, start+written-1)
		sp.saveMetadata(rm, metaPath)

		// Check if complete
		if rm. IsComplete() {
			sp.onDownloadComplete(localPath, metaPath)
		}
	}
}

// getContentLength fetches the total file size via HEAD request
func (sp *StreamProxy) getContentLength(url string) (int64, error) {
	resp, err := http.Head(url)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	return resp.ContentLength, nil
}

// hashURL creates a unique file ID from URL
func hashURL(url string) string {
	// Simple hash - use crypto/sha256 in production
	return fmt.Sprintf("%x", url)[:16]
}

// loadMetadata loads range data from disk
func (sp *StreamProxy) loadMetadata(rm *RangeManager, path string) {
	// Implementation: Read JSON file with ranges
	// Omitted for brevity
}

// saveMetadata persists range data to disk
func (sp *StreamProxy) saveMetadata(rm *RangeManager, path string) {
	// Implementation: Write JSON file with ranges
	// Omitted for brevity
}

// onDownloadComplete moves file to collection
func (sp *StreamProxy) onDownloadComplete(videoPath, metaPath string) {
	// 1. Delete metadata file
	os. Remove(metaPath)
	// 2. Move to collections folder
	// 3.  Notify Flutter UI
}