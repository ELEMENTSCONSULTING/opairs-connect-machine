// Copyright 2026 ELEMENTS Consulting GmbH

package iodd_mirror

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// DefaultSourceAPI ist der offizielle IODDfinder der IO-Link Community
// (dieselbe Adresse steht als Kommentar in sensorconnect_plugin/ioddfinder.go).
const DefaultSourceAPI = "https://ioddfinder.io-link.com/api"

// Fetch laedt die neueste IODD fuer (vendorID, deviceID) von einer
// IODDfinder-kompatiblen Quelle und speichert sie als ZIP in outDir.
// Die Datei wird vor dem Speichern geprueft (gueltiges ZIP mit einer
// passenden Haupt-IODD). Rueckgabe ist der Pfad der gespeicherten Datei.
func Fetch(ctx context.Context, client *http.Client, api string, vendorID, deviceID int64, outDir string) (string, error) {
	if client == nil {
		client = &http.Client{Timeout: 60 * time.Second}
	}
	api = strings.TrimRight(api, "/")

	body, err := get(ctx, client, fmt.Sprintf(
		"%s/drivers?page=0&size=2000&status=APPROVED&status=UPLOADED&deviceIdString=%d", api, deviceID), 16<<20)
	if err != nil {
		return "", err
	}
	var resp DriversResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("Antwort von /drivers ist kein gueltiges JSON: %w", err)
	}

	var best *Content
	for i := range resp.Content {
		c := &resp.Content[i]
		if c.VendorID != vendorID || c.DeviceID != deviceID {
			continue
		}
		if best == nil || c.UploadDate > best.UploadDate {
			best = c
		}
	}
	if best == nil {
		return "", fmt.Errorf("%w fuer vendorId=%d deviceId=%d", ErrNotFound, vendorID, deviceID)
	}

	data, err := get(ctx, client, fmt.Sprintf("%s/vendors/%d/iodds/%d/files/zip/rated", api, vendorID, best.IoddID), MaxZIPSize)
	if err != nil {
		return "", err
	}
	if err := validateZIP(data, vendorID, deviceID); err != nil {
		return "", err
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return "", err
	}
	name := fmt.Sprintf("%d-%d-%d.zip", vendorID, deviceID, best.IoddID)
	final := filepath.Join(outDir, name)
	tmp, err := os.CreateTemp(outDir, ".fetch-*.zip")
	if err != nil {
		return "", err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return "", err
	}
	// CreateTemp legt 0600 an; der Mirror laeuft als anderer Benutzer.
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	if err := os.Rename(tmp.Name(), final); err != nil {
		return "", err
	}
	return final, nil
}

func validateZIP(data []byte, vendorID, deviceID int64) error {
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return fmt.Errorf("heruntergeladene Datei ist kein gueltiges ZIP: %w", err)
	}
	for _, f := range zr.File {
		if !strings.EqualFold(filepath.Ext(f.Name), ".xml") || f.UncompressedSize64 > MaxXMLSize {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		x, err := io.ReadAll(io.LimitReader(rc, MaxXMLSize+1))
		rc.Close()
		if err != nil || len(x) > MaxXMLSize {
			continue
		}
		if e, ok, _ := parseIODD(x, f.Name, f.Name, time.Time{}); ok && e.VendorID == vendorID && e.DeviceID == deviceID {
			return nil
		}
	}
	return fmt.Errorf("ZIP enthaelt keine IODD fuer vendorId=%d deviceId=%d", vendorID, deviceID)
}

func get(ctx context.Context, client *http.Client, url string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "opairs-iodd-mirror")
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: HTTP %d", url, res.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("GET %s: Antwort groesser als %d Bytes", url, limit)
	}
	return data, nil
}
