// Copyright 2026 ELEMENTS Consulting GmbH

package iodd_mirror

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// IODDXML erzeugt eine minimale, aber strukturell echte IODD 1.1.
func IODDXML(vendor, device int64, version, release, product string) []byte {
	return []byte(fmt.Sprintf(`<?xml version="1.0" encoding="utf-8"?>
<IODevice xmlns="http://www.io-link.com/IODD/2010/10" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <DocumentInfo version="%s" releaseDate="%s" copyright="Test"/>
  <ProfileHeader>
    <ProfileIdentification>IO Device Profile</ProfileIdentification>
    <ProfileRevision>1.1</ProfileRevision>
    <ProfileName>Device Profile for IO Devices</ProfileName>
  </ProfileHeader>
  <ProfileBody>
    <DeviceIdentity vendorId="%d" vendorName="Test Vendor" deviceId="%d">
      <VendorText textId="TI_VendorText"/>
      <DeviceVariantCollection>
        <DeviceVariant productId="%s" deviceSymbol="sym.png"/>
      </DeviceVariantCollection>
    </DeviceIdentity>
    <DeviceFunction>
      <ProcessDataCollection>
        <ProcessData id="PD">
          <ProcessDataIn id="PDIn" bitLength="16">
            <Datatype xsi:type="UIntegerT" bitLength="16"/>
            <Name textId="TI_PDIn"/>
          </ProcessDataIn>
        </ProcessData>
      </ProcessDataCollection>
    </DeviceFunction>
  </ProfileBody>
  <ExternalTextCollection>
    <PrimaryLanguage xml:lang="en">
      <Text id="TI_VendorText" value="Test Vendor"/>
      <Text id="TI_PDIn" value="Value"/>
    </PrimaryLanguage>
  </ExternalTextCollection>
</IODevice>
`, version, release, vendor, device, product))
}

// LangXML ist eine Sprachdatei (keine Haupt-IODD).
var LangXML = []byte(`<?xml version="1.0" encoding="utf-8"?>
<ExternalTextDocument xmlns="http://www.io-link.com/IODD/2010/10">
  <Language xml:lang="de"><Text id="TI_VendorText" value="Test"/></Language>
</ExternalTextDocument>`)

func writeZIP(t *testing.T, path string, files map[string][]byte) {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, data := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write(data)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

// fixtureDir: eine alte Version als XML, eine neue in einem ZIP mit
// Sprachdatei und Bild, dazu Dateien, die ignoriert werden muessen.
func fixtureDir(t *testing.T) (string, []byte) {
	t.Helper()
	dir := t.TempDir()
	newXML := IODDXML(310, 967, "V2.0", "2023-04-10", "DTI410")
	os.WriteFile(filepath.Join(dir, "ifm-000967-20200101-IODD1.1.xml"), IODDXML(310, 967, "V1.0", "2020-01-01", "DTI410"), 0o644)
	writeZIP(t, filepath.Join(dir, "ifm-DTI410.zip"), map[string][]byte{
		"ifm-000967-20230410-IODD1.1.xml":    newXML,
		"ifm-000967-20230410-IODD1.1-de.xml": LangXML,
		"ifm-sym.png":                        {0x89, 'P', 'N', 'G'},
	})
	os.WriteFile(filepath.Join(dir, "kaputt.xml"), []byte("<IODevice><ProfileBody>"), 0o644)
	os.WriteFile(filepath.Join(dir, "keine-iodd.xml"), []byte(`<foo vendorId="1"/>`), 0o644)
	os.WriteFile(filepath.Join(dir, "kaputt.zip"), []byte("PK nicht wirklich"), 0o644)
	os.WriteFile(filepath.Join(dir, "README.md"), []byte("# hallo"), 0o644)
	os.MkdirAll(filepath.Join(dir, ".versteckt"), 0o755)
	os.WriteFile(filepath.Join(dir, ".versteckt", "x.xml"), IODDXML(1, 1, "V1", "2020-01-01", "X"), 0o644)
	return dir, newXML
}

func newServer(t *testing.T, dir string) (*Mirror, *httptest.Server) {
	t.Helper()
	m, err := New(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(m.Handler())
	t.Cleanup(srv.Close)
	return m, srv
}

func getJSON(t *testing.T, url string, v interface{}) (int, []byte) {
	t.Helper()
	res, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if v != nil && res.StatusCode == http.StatusOK {
		if err := json.Unmarshal(body, v); err != nil {
			t.Fatalf("JSON: %v\n%s", err, body)
		}
	}
	return res.StatusCode, body
}

func TestScanIgnoresNonIODDFiles(t *testing.T) {
	dir, _ := fixtureDir(t)
	m, err := New(dir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.Count(); got != 2 {
		t.Fatalf("erwartet 2 IODDs (XML + Haupt-XML aus ZIP), erhalten %d", got)
	}
}

func TestNewFailsForMissingDir(t *testing.T) {
	if _, err := New(filepath.Join(t.TempDir(), "gibtsnicht"), nil); err == nil {
		t.Fatal("Fehler erwartet")
	}
}

func TestDriversLikePluginQuery(t *testing.T) {
	dir, _ := fixtureDir(t)
	_, srv := newServer(t, dir)

	// exakt die Abfrage aus sensorconnect_plugin/ioddfinder.go
	var resp DriversResponse
	code, raw := getJSON(t, srv.URL+"/drivers?page=0&size=2000&status=APPROVED&status=UPLOADED&deviceIdString=967", &resp)
	if code != 200 {
		t.Fatalf("HTTP %d: %s", code, raw)
	}
	if len(resp.Content) != 2 || resp.TotalElements != 2 || !resp.First || !resp.Last {
		t.Fatalf("unerwartete Antwort: %+v", resp)
	}
	a, b := resp.Content[0], resp.Content[1]
	if a.UploadDate <= b.UploadDate {
		t.Fatalf("neueste Version zuerst erwartet: %d <= %d", a.UploadDate, b.UploadDate)
	}
	if a.VersionString != "V2.0" || a.VendorID != 310 || a.DeviceID != 967 || a.ProductID != "DTI410" || a.VendorName != "Test Vendor" {
		t.Fatalf("Felder falsch: %+v", a)
	}
	if a.IoddID == b.IoddID || a.IoddID <= 0 || !a.HasMoreVersions {
		t.Fatalf("IDs/hasMoreVersions falsch: %+v / %+v", a, b)
	}
	for _, key := range []string{`"content"`, `"vendorId"`, `"ioddId"`, `"uploadDate"`, `"totalElements"`} {
		if !strings.Contains(string(raw), key) {
			t.Fatalf("Feld %s fehlt in JSON", key)
		}
	}
}

func TestDriversUnknownDeviceIsEmpty200(t *testing.T) {
	dir, _ := fixtureDir(t)
	_, srv := newServer(t, dir)
	code, raw := getJSON(t, srv.URL+"/drivers?deviceIdString=4711", nil)
	if code != 200 {
		t.Fatalf("200 erwartet (404 wuerde Retries im Plugin ausloesen), erhalten %d", code)
	}
	if !strings.Contains(string(raw), `"content": []`) {
		t.Fatalf("leere Liste erwartet, nicht null: %s", raw)
	}
}

func TestDriversVendorFilterAndBadInput(t *testing.T) {
	dir, _ := fixtureDir(t)
	_, srv := newServer(t, dir)
	var resp DriversResponse
	getJSON(t, srv.URL+"/drivers?deviceIdString=967&vendorId=999", &resp)
	if len(resp.Content) != 0 {
		t.Fatalf("Herstellerfilter greift nicht: %+v", resp)
	}
	for _, q := range []string{"", "?deviceIdString=", "?deviceIdString=abc", "?deviceIdString=-5", "?deviceIdString=967&vendorId=x"} {
		if code, _ := getJSON(t, srv.URL+"/drivers"+q, nil); code != 400 {
			t.Fatalf("%q: 400 erwartet, erhalten %d", q, code)
		}
	}
}

func TestZIPContainsOnlyMainIODD(t *testing.T) {
	dir, newXML := fixtureDir(t)
	_, srv := newServer(t, dir)
	var resp DriversResponse
	getJSON(t, srv.URL+"/drivers?deviceIdString=967", &resp)
	newest := resp.Content[0]

	res, err := http.Get(fmt.Sprintf("%s/vendors/%d/iodds/%d/files/zip/rated", srv.URL, newest.VendorID, newest.IoddID))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "application/zip" {
		t.Fatalf("HTTP %d, Content-Type %q", res.StatusCode, res.Header.Get("Content-Type"))
	}
	data, _ := io.ReadAll(res.Body)
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	if len(zr.File) != 1 || zr.File[0].Name != "ifm-000967-20230410-IODD1.1.xml" {
		t.Fatalf("genau eine Haupt-XML erwartet, erhalten %d Dateien", len(zr.File))
	}
	rc, _ := zr.File[0].Open()
	got, _ := io.ReadAll(rc)
	rc.Close()
	if !bytes.Equal(got, newXML) {
		t.Fatal("XML im ZIP weicht vom Original ab")
	}
}

func TestZIPErrors(t *testing.T) {
	dir, _ := fixtureDir(t)
	_, srv := newServer(t, dir)
	cases := map[string]int{
		"/vendors/310/iodds/1/files/zip/rated":  404,
		"/vendors/abc/iodds/1/files/zip/rated":  400,
		"/vendors/310/iodds/../files/zip/rated": 404,
		"/vendors/310/iodds/1/files/zip/other":  404,
	}
	for path, want := range cases {
		res, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != want {
			t.Fatalf("%s: %d erwartet, erhalten %d", path, want, res.StatusCode)
		}
	}
}

func TestOnlyGET(t *testing.T) {
	dir, _ := fixtureDir(t)
	_, srv := newServer(t, dir)
	res, err := http.Post(srv.URL+"/drivers?deviceIdString=967", "text/plain", nil)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("405 erwartet, erhalten %d", res.StatusCode)
	}
}

func TestHealthzAndList(t *testing.T) {
	dir, _ := fixtureDir(t)
	_, srv := newServer(t, dir)
	code, body := getJSON(t, srv.URL+"/healthz", nil)
	if code != 200 || !strings.HasPrefix(string(body), "ok 2") {
		t.Fatalf("healthz: %d %q", code, body)
	}
	var items []ListItem
	getJSON(t, srv.URL+"/", &items)
	if len(items) != 2 || items[0].Source == "" || items[0].Released == "" {
		t.Fatalf("Liste: %+v", items)
	}
}

func TestIDsStableAndRescan(t *testing.T) {
	dir, _ := fixtureDir(t)
	m1, _ := New(dir, nil)
	m2, _ := New(dir, nil)
	ids := func(m *Mirror) []int64 {
		var out []int64
		for _, e := range m.idx.all {
			out = append(out, e.IoddID)
		}
		return out
	}
	if fmt.Sprint(ids(m1)) != fmt.Sprint(ids(m2)) {
		t.Fatalf("IDs nicht stabil: %v vs %v", ids(m1), ids(m2))
	}

	os.WriteFile(filepath.Join(dir, "neu.xml"), IODDXML(42, 278531, "V1", "2024-01-01", "SIRIUS"), 0o644)
	if err := m1.Rescan(); err != nil {
		t.Fatal(err)
	}
	if m1.Count() != 3 {
		t.Fatalf("nach Rescan 3 erwartet, erhalten %d", m1.Count())
	}
}

func TestReleaseDateFallbackToMtime(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.xml"), IODDXML(1, 2, "V1", "kein-datum", "A"), 0o644)
	m, _ := New(dir, nil)
	if m.Count() != 1 || m.idx.all[0].UploadDate <= 0 {
		t.Fatalf("Fallback auf Dateidatum greift nicht: %+v", m.idx.all)
	}
}

func TestFetchFromCompatibleSource(t *testing.T) {
	srcDir, newXML := fixtureDir(t)
	_, src := newServer(t, srcDir) // der Mirror selbst ist eine kompatible Quelle
	out := t.TempDir()

	path, err := Fetch(context.Background(), nil, src.URL+"/", 310, 967, out)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(filepath.Base(path), "310-967-") {
		t.Fatalf("Dateiname: %s", path)
	}
	m, _ := New(out, nil)
	if m.Count() != 1 || !bytes.Equal(m.idx.all[0].XML, newXML) {
		t.Fatal("geladene Datei enthaelt nicht die neueste IODD")
	}

	if _, err := Fetch(context.Background(), nil, src.URL, 310, 4711, out); !errors.Is(err, ErrNotFound) {
		t.Fatalf("ErrNotFound erwartet, erhalten %v", err)
	}
}

func TestFetchRejectsInvalidZIP(t *testing.T) {
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/drivers") {
			fmt.Fprint(w, `{"content":[{"vendorId":310,"deviceId":967,"ioddId":5,"uploadDate":1}]}`)
			return
		}
		w.Write([]byte("kein zip"))
	}))
	defer fake.Close()
	out := t.TempDir()
	if _, err := Fetch(context.Background(), nil, fake.URL, 310, 967, out); err == nil {
		t.Fatal("Fehler erwartet")
	}
	entries, _ := os.ReadDir(out)
	if len(entries) != 0 {
		t.Fatalf("keine Dateien erwartet, gefunden: %v", entries)
	}
}
