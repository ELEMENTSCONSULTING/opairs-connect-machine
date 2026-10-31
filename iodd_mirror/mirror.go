// Copyright 2026 ELEMENTS Consulting GmbH
//
// Package iodd_mirror stellt IODD-Dateien (IO Device Descriptions) aus einem
// lokalen Ordner ueber dieselbe HTTP-Schnittstelle bereit, die das
// sensorconnect-Plugin beim IODDfinder abfragt. Damit funktioniert die
// automatische Erkennung von IO-Link-Sensoren ohne Internetzugang.
//
// Nachgebildet werden genau die zwei Abfragen des Plugins
// (sensorconnect_plugin/ioddfinder.go):
//
//	GET /drivers?...&deviceIdString=<deviceId>
//	GET /vendors/<vendorId>/iodds/<ioddId>/files/zip/rated
//
// Nur Go-Standardbibliothek.
package iodd_mirror

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Grenzen gegen defekte oder boesartige Dateien im Ordner.
const (
	MaxXMLSize = 32 << 20  // eine IODD-XML
	MaxZIPSize = 128 << 20 // ein IODD-Paket
)

// Content entspricht einem Eintrag der IODDfinder-Antwort. Die Feldnamen
// muessen zu sensorconnect_plugin.Content passen.
type Content struct {
	ProductName        string `json:"productName"`
	IndicationOfSource string `json:"indicationOfSource"`
	IoLinkRev          string `json:"ioLinkRev"`
	VersionString      string `json:"versionString"`
	IoddStatus         string `json:"ioddStatus"`
	ProductID          string `json:"productId"`
	VendorName         string `json:"vendorName"`
	ProductVariantID   int64  `json:"productVariantId"`
	UploadDate         int64  `json:"uploadDate"`
	VendorID           int64  `json:"vendorId"`
	IoddID             int64  `json:"ioddId"`
	DeviceID           int64  `json:"deviceId"`
	HasMoreVersions    bool   `json:"hasMoreVersions"`
}

// DriversResponse entspricht der Antwort von /drivers (Spring-Page-Format).
type DriversResponse struct {
	Content          []Content     `json:"content"`
	Sort             []interface{} `json:"sort"`
	Number           int64         `json:"number"`
	Size             int64         `json:"size"`
	NumberOfElements int64         `json:"numberOfElements"`
	TotalPages       int64         `json:"totalPages"`
	TotalElements    int64         `json:"totalElements"`
	First            bool          `json:"first"`
	Last             bool          `json:"last"`
}

// Entry ist eine indizierte IODD.
type Entry struct {
	Content
	Source  string // Pfad relativ zum Ordner (bei ZIP: "paket.zip!datei.xml")
	XMLName string // Dateiname der XML (im ausgelieferten ZIP)
	XML     []byte
}

type index struct {
	byDevice map[int64][]*Entry  // deviceId -> Eintraege
	byID     map[[2]int64]*Entry // (vendorId, ioddId) -> Eintrag
	all      []*Entry
}

// Mirror haelt den Index eines Ordners.
type Mirror struct {
	Dir    string
	Logger *log.Logger

	mu  sync.RWMutex
	idx *index
}

// New erstellt einen Mirror und liest den Ordner einmal ein.
func New(dir string, logger *log.Logger) (*Mirror, error) {
	if logger == nil {
		logger = log.New(io.Discard, "", 0)
	}
	m := &Mirror{Dir: dir, Logger: logger}
	if err := m.Rescan(); err != nil {
		return nil, err
	}
	return m, nil
}

// Count liefert die Zahl der indizierten IODDs.
func (m *Mirror) Count() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.idx.all)
}

// Rescan liest den Ordner neu ein und tauscht den Index atomar aus.
// Einzelne fehlerhafte Dateien werden protokolliert und uebersprungen.
func (m *Mirror) Rescan() error {
	st, err := os.Stat(m.Dir)
	if err != nil {
		return fmt.Errorf("IODD-Ordner %q: %w", m.Dir, err)
	}
	if !st.IsDir() {
		return fmt.Errorf("IODD-Ordner %q ist kein Verzeichnis", m.Dir)
	}

	idx := &index{byDevice: map[int64][]*Entry{}, byID: map[[2]int64]*Entry{}}
	err = filepath.WalkDir(m.Dir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			m.Logger.Printf("WARN %s: %v", path, walkErr)
			return nil
		}
		if d.IsDir() {
			if path != m.Dir && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(d.Name(), ".") {
			return nil // versteckte Dateien (z. B. abgebrochene Downloads)
		}
		rel, _ := filepath.Rel(m.Dir, path)
		rel = filepath.ToSlash(rel)
		info, err := os.Stat(path) // folgt Symlinks, damit die Groessengrenze greift
		if err != nil {
			m.Logger.Printf("WARN %s: %v", rel, err)
			return nil
		}
		switch strings.ToLower(filepath.Ext(d.Name())) {
		case ".xml":
			if info.Size() > MaxXMLSize {
				m.Logger.Printf("WARN %s: groesser als %d Bytes, uebersprungen", rel, MaxXMLSize)
				return nil
			}
			data, err := os.ReadFile(path)
			if err != nil {
				m.Logger.Printf("WARN %s: %v", rel, err)
				return nil
			}
			e, ok, perr := parseIODD(data, d.Name(), rel, info.ModTime())
			if perr != nil {
				m.Logger.Printf("WARN %s: keine lesbare XML, uebersprungen: %v", rel, perr)
			}
			if ok {
				idx.add(e)
			}
		case ".zip":
			if info.Size() > MaxZIPSize {
				m.Logger.Printf("WARN %s: groesser als %d Bytes, uebersprungen", rel, MaxZIPSize)
				return nil
			}
			for _, e := range m.readZIP(path, rel, info.ModTime()) {
				idx.add(e)
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	idx.finish()

	m.mu.Lock()
	old := 0
	if m.idx != nil {
		old = len(m.idx.all)
	}
	m.idx = idx
	m.mu.Unlock()

	if old != len(idx.all) {
		m.Logger.Printf("INFO %d IODD(s) im Index (vorher %d)", len(idx.all), old)
	}
	return nil
}

func (m *Mirror) readZIP(path, rel string, mod time.Time) []*Entry {
	zr, err := zip.OpenReader(path)
	if err != nil {
		m.Logger.Printf("WARN %s: kein gueltiges ZIP: %v", rel, err)
		return nil
	}
	defer zr.Close()

	var out []*Entry
	for _, f := range zr.File {
		if f.FileInfo().IsDir() || !strings.EqualFold(filepath.Ext(f.Name), ".xml") {
			continue
		}
		if f.UncompressedSize64 > MaxXMLSize {
			m.Logger.Printf("WARN %s!%s: groesser als %d Bytes, uebersprungen", rel, f.Name, MaxXMLSize)
			continue
		}
		rc, err := f.Open()
		if err != nil {
			m.Logger.Printf("WARN %s!%s: %v", rel, f.Name, err)
			continue
		}
		// Groesse zusaetzlich beim Lesen begrenzen (Angabe im ZIP kann falsch sein).
		data, err := io.ReadAll(io.LimitReader(rc, MaxXMLSize+1))
		rc.Close()
		if err != nil || len(data) > MaxXMLSize {
			m.Logger.Printf("WARN %s!%s: nicht lesbar oder zu gross", rel, f.Name)
			continue
		}
		name := filepath.Base(filepath.FromSlash(f.Name))
		e, ok, perr := parseIODD(data, name, rel+"!"+f.Name, mod)
		if perr != nil {
			m.Logger.Printf("WARN %s!%s: keine lesbare XML, uebersprungen: %v", rel, f.Name, perr)
		}
		if ok {
			out = append(out, e)
		}
	}
	return out
}

// ioddDoc enthaelt die Teile einer IODD, die fuer den Index gebraucht
// werden. encoding/xml vergleicht nur lokale Namen, der IODD-Namespace
// spielt daher keine Rolle.
type ioddDoc struct {
	XMLName      xml.Name
	DocumentInfo struct {
		Version     string `xml:"version,attr"`
		ReleaseDate string `xml:"releaseDate,attr"`
	} `xml:"DocumentInfo"`
	ProfileHeader struct {
		ProfileRevision string `xml:"ProfileRevision"`
	} `xml:"ProfileHeader"`
	ProfileBody struct {
		DeviceIdentity struct {
			VendorID   int64  `xml:"vendorId,attr"`
			DeviceID   int64  `xml:"deviceId,attr"`
			VendorName string `xml:"vendorName,attr"`
			Variants   []struct {
				ProductID string `xml:"productId,attr"`
			} `xml:"DeviceVariantCollection>DeviceVariant"`
		} `xml:"DeviceIdentity"`
	} `xml:"ProfileBody"`
}

// parseIODD erkennt eine Haupt-IODD (Wurzel IODevice mit DeviceIdentity).
// Sprachdateien, Bilder und andere gueltige XMLs liefern ok=false ohne
// Fehler; err ist nur bei nicht lesbarer XML gesetzt.
//
// IODDs in ISO-8859-1 / Windows-1252 werden nach UTF-8 umgewandelt (auch die
// ausgelieferte Datei), weil das Plugin nur UTF-8 lesen kann.
func parseIODD(data []byte, fileName, source string, mod time.Time) (*Entry, bool, error) {
	data = toUTF8(data)
	var doc ioddDoc
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, false, err
	}
	id := doc.ProfileBody.DeviceIdentity
	if doc.XMLName.Local != "IODevice" || id.VendorID <= 0 || id.DeviceID <= 0 {
		return nil, false, nil
	}

	upload := mod.UnixMilli()
	if t, err := time.Parse("2006-01-02", strings.TrimSpace(doc.DocumentInfo.ReleaseDate)); err == nil {
		upload = t.UnixMilli()
	}

	var products []string
	for _, v := range id.Variants {
		if v.ProductID != "" {
			products = append(products, v.ProductID)
		}
	}
	base := strings.TrimSuffix(fileName, filepath.Ext(fileName))

	return &Entry{
		Content: Content{
			ProductName:        base,
			IndicationOfSource: "local",
			IoLinkRev:          doc.ProfileHeader.ProfileRevision,
			VersionString:      doc.DocumentInfo.Version,
			IoddStatus:         "APPROVED",
			ProductID:          strings.Join(products, ", "),
			VendorName:         id.VendorName,
			UploadDate:         upload,
			VendorID:           id.VendorID,
			DeviceID:           id.DeviceID,
		},
		Source: source,
		// Das Plugin uebernimmt nur ZIP-Eintraege, die auf kleingeschriebenes
		// "xml" enden (sonst Absturz), daher immer ".xml".
		XMLName: base + ".xml",
		XML:     data,
	}, true, nil
}

var encodingDecl = regexp.MustCompile(`(?i)^(\s*<\?xml[^>]*?encoding\s*=\s*["'])([^"']+)(["'])`)

// cp1252 belegt 0x80-0x9F anders als ISO-8859-1.
var cp1252 = [32]rune{
	0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
	0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
}

// toUTF8 wandelt ISO-8859-1/Windows-1252 nach UTF-8 und passt die
// XML-Deklaration an. Andere Kodierungen bleiben unveraendert.
func toUTF8(data []byte) []byte {
	head := data
	if len(head) > 256 {
		head = head[:256]
	}
	m := encodingDecl.FindSubmatchIndex(head)
	if m == nil {
		return data
	}
	enc := strings.ToLower(string(head[m[4]:m[5]]))
	var win bool
	switch enc {
	case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1":
	case "windows-1252", "cp1252":
		win = true
	default:
		return data
	}
	var b strings.Builder
	b.Grow(len(data) + len(data)/8)
	b.Write(data[:m[4]])
	b.WriteString("UTF-8")
	for _, c := range data[m[5]:] {
		switch {
		case c < 0x80:
			b.WriteByte(c)
		case win && c < 0xA0:
			b.WriteRune(cp1252[c-0x80])
		default:
			b.WriteRune(rune(c))
		}
	}
	return []byte(b.String())
}

func (idx *index) add(e *Entry) {
	// Stabile ID aus der Quelle, damit Neustarts dieselben IDs liefern.
	h := fnv.New32a()
	h.Write([]byte(e.Source))
	id := int64(h.Sum32() & 0x7fffffff)
	if id == 0 {
		id = 1
	}
	for {
		if _, taken := idx.byID[[2]int64{e.VendorID, id}]; !taken {
			break
		}
		id++
	}
	e.IoddID = id
	idx.byID[[2]int64{e.VendorID, id}] = e
	idx.byDevice[e.DeviceID] = append(idx.byDevice[e.DeviceID], e)
	idx.all = append(idx.all, e)
}

func (idx *index) finish() {
	sort.Slice(idx.all, func(i, j int) bool { return idx.all[i].Source < idx.all[j].Source })
	for _, list := range idx.byDevice {
		sort.Slice(list, func(i, j int) bool {
			if list[i].UploadDate != list[j].UploadDate {
				return list[i].UploadDate > list[j].UploadDate
			}
			if list[i].IoLinkRev != list[j].IoLinkRev {
				return list[i].IoLinkRev > list[j].IoLinkRev // "1.1" vor "1.0"
			}
			return list[i].Source < list[j].Source
		})
		// mehrere Versionen desselben Geraets?
		per := map[int64]int{}
		for _, e := range list {
			per[e.VendorID]++
		}
		for _, e := range list {
			e.HasMoreVersions = per[e.VendorID] > 1
		}
	}
}

// Handler liefert den HTTP-Handler mit allen Endpunkten.
func (m *Mirror) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /drivers", m.handleDrivers)
	mux.HandleFunc("GET /vendors/{vendor}/iodds/{iodd}/files/zip/rated", m.handleZIP)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintf(w, "ok %d\n", m.Count())
	})
	mux.HandleFunc("GET /{$}", m.handleList)
	return mux
}

// handleDrivers beantwortet die Suche nach einer Geraete-ID.
// Unbekannte Geraete liefern 200 mit leerer Liste (wie der IODDfinder).
// Wichtig: Ein 404 wuerde das Plugin bis zu 10-mal mit Wartezeit wiederholen
// lassen, bevor es auf Rohdaten umschaltet.
func (m *Mirror) handleDrivers(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("deviceIdString")
	deviceID, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil || deviceID <= 0 {
		http.Error(w, "deviceIdString fehlt oder ist keine positive Zahl", http.StatusBadRequest)
		return
	}
	var vendorFilter int64
	if v := r.URL.Query().Get("vendorId"); v != "" {
		if vendorFilter, err = strconv.ParseInt(v, 10, 64); err != nil {
			http.Error(w, "vendorId ist keine Zahl", http.StatusBadRequest)
			return
		}
	}

	m.mu.RLock()
	list := m.idx.byDevice[deviceID]
	resp := DriversResponse{Content: []Content{}, Sort: []interface{}{}, TotalPages: 1, First: true, Last: true}
	for _, e := range list {
		if vendorFilter == 0 || e.VendorID == vendorFilter {
			resp.Content = append(resp.Content, e.Content)
		}
	}
	m.mu.RUnlock()

	n := int64(len(resp.Content))
	resp.Size, resp.NumberOfElements, resp.TotalElements = n, n, n
	m.Logger.Printf("INFO drivers deviceId=%d -> %d Treffer", deviceID, n)
	writeJSON(w, resp)
}

// handleZIP liefert ein ZIP mit genau der Haupt-IODD-XML. Das Plugin liest
// alle .xml-Dateien eines ZIPs; Sprachdateien werden deshalb nicht
// mitgeliefert, damit es sicher die richtige Datei verwendet.
func (m *Mirror) handleZIP(w http.ResponseWriter, r *http.Request) {
	vendor, err1 := strconv.ParseInt(r.PathValue("vendor"), 10, 64)
	iodd, err2 := strconv.ParseInt(r.PathValue("iodd"), 10, 64)
	if err1 != nil || err2 != nil {
		http.Error(w, "vendor und iodd muessen Zahlen sein", http.StatusBadRequest)
		return
	}
	m.mu.RLock()
	e := m.idx.byID[[2]int64{vendor, iodd}]
	m.mu.RUnlock()
	if e == nil {
		http.NotFound(w, r)
		return
	}

	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	fw, err := zw.CreateHeader(&zip.FileHeader{Name: e.XMLName, Method: zip.Deflate, Modified: time.UnixMilli(e.UploadDate).UTC()})
	if err == nil {
		_, err = fw.Write(e.XML)
	}
	if err == nil {
		err = zw.Close()
	}
	if err != nil {
		http.Error(w, "ZIP konnte nicht erstellt werden", http.StatusInternalServerError)
		return
	}
	m.Logger.Printf("INFO zip vendorId=%d ioddId=%d (%s)", vendor, iodd, e.Source)
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", strings.TrimSuffix(e.XMLName, filepath.Ext(e.XMLName))+".zip"))
	w.Write(buf.Bytes())
}

// ListItem ist ein Eintrag der Uebersicht unter "/".
type ListItem struct {
	VendorID   int64  `json:"vendorId"`
	VendorName string `json:"vendorName"`
	DeviceID   int64  `json:"deviceId"`
	IoddID     int64  `json:"ioddId"`
	ProductID  string `json:"productId"`
	Version    string `json:"version"`
	Released   string `json:"released"`
	Source     string `json:"source"`
}

func (m *Mirror) handleList(w http.ResponseWriter, _ *http.Request) {
	m.mu.RLock()
	items := make([]ListItem, 0, len(m.idx.all))
	for _, e := range m.idx.all {
		items = append(items, ListItem{
			VendorID: e.VendorID, VendorName: e.VendorName, DeviceID: e.DeviceID, IoddID: e.IoddID,
			ProductID: e.ProductID, Version: e.VersionString,
			Released: time.UnixMilli(e.UploadDate).UTC().Format("2006-01-02"), Source: e.Source,
		})
	}
	m.mu.RUnlock()
	writeJSON(w, items)
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		log.Printf("WARN JSON: %v", err)
	}
}

// ErrNotFound wird von Fetch geliefert, wenn die Quelle keine IODD kennt.
var ErrNotFound = errors.New("keine IODD gefunden")
