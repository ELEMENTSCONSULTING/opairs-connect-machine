// Copyright 2026 ELEMENTS Consulting GmbH

// iodd-mirror: lokaler IODDfinder-Ersatz fuer das sensorconnect-Plugin.
//
//	iodd-mirror serve       [-dir /data] [-listen :8080] [-rescan 60s]
//	iodd-mirror fetch       [-api URL] [-out DIR] VENDOR:DEVICE [VENDOR:DEVICE ...]
//	iodd-mirror fetch       [-api URL] [-out DIR] -list geraete.txt
//	iodd-mirror healthcheck [-url http://127.0.0.1:8080/healthz]
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	mirror "github.com/united-manufacturing-hub/benthos-umh/iodd_mirror"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "serve":
		err = serve(os.Args[2:])
	case "fetch":
		err = fetch(os.Args[2:])
	case "healthcheck":
		err = healthcheck(os.Args[2:])
	case "-h", "--help", "help":
		usage()
		return
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "Fehler:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `iodd-mirror: lokaler IODDfinder-Ersatz fuer das sensorconnect-Plugin

  iodd-mirror serve       [-dir /data] [-listen :8080] [-rescan 60s]
  iodd-mirror fetch       [-api URL] [-out DIR] VENDOR:DEVICE [...]
  iodd-mirror fetch       [-api URL] [-out DIR] -list geraete.txt
  iodd-mirror healthcheck [-url http://127.0.0.1:8080/healthz]`)
}

func serve(args []string) error {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	dir := fs.String("dir", "/data", "Ordner mit IODD-Dateien (.xml, .zip)")
	listen := fs.String("listen", ":8080", "Adresse fuer den HTTP-Server")
	rescan := fs.Duration("rescan", 60*time.Second, "Intervall zum Neueinlesen des Ordners (0 = nie)")
	fs.Parse(args)

	logger := log.New(os.Stdout, "", log.LstdFlags|log.LUTC)
	m, err := mirror.New(*dir, logger)
	if err != nil {
		return err
	}
	logger.Printf("INFO %d IODD(s) aus %s geladen", m.Count(), *dir)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if *rescan > 0 {
		go func() {
			t := time.NewTicker(*rescan)
			defer t.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-t.C:
					if err := m.Rescan(); err != nil {
						logger.Printf("WARN Neueinlesen: %v", err)
					}
				}
			}
		}()
	}

	srv := &http.Server{
		Addr:              *listen,
		Handler:           m.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe() }()
	logger.Printf("INFO lausche auf %s", *listen)

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(shutdownCtx)
	}
}

func fetch(args []string) error {
	fs := flag.NewFlagSet("fetch", flag.ExitOnError)
	api := fs.String("api", mirror.DefaultSourceAPI, "IODDfinder-kompatible Quelle")
	out := fs.String("out", "./iodd", "Zielordner")
	list := fs.String("list", "", "Datei mit einer Zeile je Geraet: VENDOR:DEVICE (# fuer Kommentare)")
	fs.Parse(args)

	specs := fs.Args()
	if *list != "" {
		lines, err := readList(*list)
		if err != nil {
			return err
		}
		specs = append(specs, lines...)
	}
	if len(specs) == 0 {
		return errors.New("keine Geraete angegeben (VENDOR:DEVICE oder -list)")
	}

	failed := 0
	for _, s := range specs {
		vendor, device, err := parseSpec(s)
		if err != nil {
			fmt.Fprintf(os.Stderr, "FEHLER %s: %v\n", s, err)
			failed++
			continue
		}
		path, err := mirror.Fetch(context.Background(), nil, *api, vendor, device, *out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "FEHLER %s: %v\n", s, err)
			failed++
			continue
		}
		fmt.Printf("OK     %s -> %s\n", s, path)
	}
	if failed > 0 {
		return fmt.Errorf("%d von %d Geraeten fehlgeschlagen", failed, len(specs))
	}
	return nil
}

func readList(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if i := strings.Index(line, "#"); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line != "" {
			out = append(out, line)
		}
	}
	return out, sc.Err()
}

func parseSpec(s string) (int64, int64, error) {
	parts := strings.FieldsFunc(s, func(r rune) bool { return r == ':' || r == ',' || r == ' ' || r == '\t' })
	if len(parts) != 2 {
		return 0, 0, errors.New("Format VENDOR:DEVICE erwartet, z. B. 310:967")
	}
	v, err1 := strconv.ParseInt(parts[0], 10, 64)
	d, err2 := strconv.ParseInt(parts[1], 10, 64)
	if err1 != nil || err2 != nil || v <= 0 || d <= 0 {
		return 0, 0, errors.New("VENDOR und DEVICE muessen positive Zahlen sein")
	}
	return v, d, nil
}

func healthcheck(args []string) error {
	fs := flag.NewFlagSet("healthcheck", flag.ExitOnError)
	url := fs.String("url", "http://127.0.0.1:8080/healthz", "Health-Endpunkt")
	fs.Parse(args)
	c := &http.Client{Timeout: 3 * time.Second}
	res, err := c.Get(*url)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", res.StatusCode)
	}
	return nil
}
