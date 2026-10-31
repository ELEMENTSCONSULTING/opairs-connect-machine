// Copyright 2026 ELEMENTS Consulting GmbH

//go:build plugincompat

// Kompatibilitaetstest gegen den echten Code des sensorconnect-Plugins.
// Braucht die Abhaengigkeiten des Hauptmoduls und laeuft deshalb in der CI:
//
//	go test -tags plugincompat ./iodd_mirror/...
package iodd_mirror_test

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	mirror "github.com/united-manufacturing-hub/benthos-umh/iodd_mirror"
	"github.com/united-manufacturing-hub/benthos-umh/sensorconnect_plugin"
)

func setup(t *testing.T) *httptest.Server {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "alt.xml"), mirror.IODDXML(310, 967, "V1.0", "2020-01-01", "DTI410"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Neue Version als XML in Unterordner, Sprachdatei daneben
	sub := filepath.Join(dir, "ifm")
	os.MkdirAll(sub, 0o755)
	os.WriteFile(filepath.Join(sub, "neu.xml"), mirror.IODDXML(310, 967, "V2.0", "2023-04-10", "DTI410"), 0o644)
	os.WriteFile(filepath.Join(sub, "neu-de.xml"), mirror.LangXML, 0o644)

	m, err := mirror.New(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(m.Handler())
	t.Cleanup(srv.Close)
	return srv
}

// Das Plugin laedt ueber den Mirror die neueste IODD und legt sie in seinen Index.
func TestPluginFetchAndStoreIoDDFile(t *testing.T) {
	srv := setup(t)
	in := &sensorconnect_plugin.SensorConnectInput{IODDAPI: srv.URL}

	if err := in.FetchAndStoreIoDDFile(context.Background(), 310, 967); err != nil {
		t.Fatalf("Plugin konnte IODD nicht laden: %v", err)
	}
	v, ok := in.IoDeviceMap.Load(sensorconnect_plugin.IoddFilemapKey{VendorId: 310, DeviceId: 967})
	if !ok {
		t.Fatal("IODD nicht im Index des Plugins")
	}
	dev, ok := v.(sensorconnect_plugin.IoDevice)
	if !ok {
		t.Fatalf("unerwarteter Typ %T", v)
	}
	if dev.DocumentInfo.ReleaseDate != "2023-04-10" {
		t.Fatalf("neueste Version erwartet, erhalten releaseDate=%q", dev.DocumentInfo.ReleaseDate)
	}
	if dev.ProfileBody.DeviceIdentity.VendorId != 310 || dev.ProfileBody.DeviceIdentity.DeviceId != 967 {
		t.Fatalf("DeviceIdentity falsch: %+v", dev.ProfileBody.DeviceIdentity)
	}
}

// GetIoddFile liefert je Version genau eine Datei (keine Sprachdateien).
func TestPluginGetIoddFile(t *testing.T) {
	srv := setup(t)
	in := &sensorconnect_plugin.SensorConnectInput{IODDAPI: srv.URL}
	files, err := in.GetIoddFile(context.Background(), 310, 967)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 {
		t.Fatalf("2 Dateien (2 Versionen) erwartet, erhalten %d", len(files))
	}
	for _, f := range files {
		if strings.Contains(f.Name, "-de") || f.Context.VendorID != 310 || f.Context.IoddID <= 0 {
			t.Fatalf("unerwartete Datei: %s %+v", f.Name, f.Context)
		}
	}
}

// Der Weg, den das Plugin beim Verbinden geht (AddNewDeviceToIoddFilesAndMap).
func TestPluginAddNewDevice(t *testing.T) {
	srv := setup(t)
	in := &sensorconnect_plugin.SensorConnectInput{IODDAPI: srv.URL}
	key := sensorconnect_plugin.IoddFilemapKey{VendorId: 310, DeviceId: 967}
	if err := in.AddNewDeviceToIoddFilesAndMap(context.Background(), key); err != nil {
		t.Fatal(err)
	}
}

// Unbekanntes Geraet: sofortiger Fehler (-> Plugin schaltet auf Rohdaten),
// keine Wiederholungen mit Wartezeit.
func TestPluginUnknownDeviceFailsFast(t *testing.T) {
	srv := setup(t)
	in := &sensorconnect_plugin.SensorConnectInput{IODDAPI: srv.URL}
	start := time.Now()
	err := in.FetchAndStoreIoDDFile(context.Background(), 310, 4711)
	if err == nil || !strings.Contains(err.Error(), "No IODD file") {
		t.Fatalf("Fehler 'No IODD file' erwartet, erhalten %v", err)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("zu langsam (%v): Plugin hat wiederholt", d)
	}
}
