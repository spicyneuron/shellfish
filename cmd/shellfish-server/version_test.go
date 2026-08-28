package main

import (
	"os"
	"strings"
	"testing"
)

func TestVersionMatchesRepository(t *testing.T) {
	contents, err := os.ReadFile("../../VERSION")
	if err != nil {
		t.Fatal(err)
	}
	if want := strings.TrimSpace(string(contents)); version != want {
		t.Fatalf("server version = %q, VERSION = %q", version, want)
	}
}
