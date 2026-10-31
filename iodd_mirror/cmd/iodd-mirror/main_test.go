// Copyright 2026 ELEMENTS Consulting GmbH

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseSpec(t *testing.T) {
	ok := map[string][2]int64{"310:967": {310, 967}, "42,278531": {42, 278531}, " 287 2228227 ": {287, 2228227}}
	for in, want := range ok {
		v, d, err := parseSpec(in)
		if err != nil || v != want[0] || d != want[1] {
			t.Fatalf("%q: %d %d %v", in, v, d, err)
		}
	}
	for _, in := range []string{"", "310", "a:b", "0:5", "1:2:3", "-1:5"} {
		if _, _, err := parseSpec(in); err == nil {
			t.Fatalf("%q: Fehler erwartet", in)
		}
	}
}

func TestReadList(t *testing.T) {
	p := filepath.Join(t.TempDir(), "l.txt")
	os.WriteFile(p, []byte("# Kommentar\n310:967  # DTI410\n\n42:278531\n"), 0o644)
	got, err := readList(p)
	if err != nil || !reflect.DeepEqual(got, []string{"310:967", "42:278531"}) {
		t.Fatalf("%v %v", got, err)
	}
}
