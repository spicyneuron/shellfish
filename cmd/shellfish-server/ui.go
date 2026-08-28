package main

import (
	_ "embed"
	"log"
	"net/http"
)

//go:embed ui/ui.html
var uiHTML []byte

//go:embed ui/ui.css
var uiCSS []byte

//go:embed ui/ui.js
var uiJS []byte

// The page is served without an access code because it carries nothing worth
// protecting: it is an empty prompt, and every request it goes on to make is
// authorized the same way any other client's is.
//
// A turn is command execution as the service account, so a script injected into
// this page would be a shell. It is confined to its own origin and its own three
// assets: no inline script, no remote anything, nowhere else to send what it
// reads.
const uiContentSecurityPolicy = "default-src 'none'; script-src 'self'; " +
	"style-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; " +
	"frame-ancestors 'none'"

// withUI serves the bundled page in front of the API. The page is the only part
// of the service that answers without an access code, so it is a layer rather
// than a branch inside the authenticated API.
func withUI(api http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && serveUI(w, r.URL.Path) {
			log.Printf("ui served path=%q remote=%q", r.URL.Path, r.RemoteAddr)
			return
		}
		api.ServeHTTP(w, r)
	})
}

// serveUI answers with a bundled asset, reporting whether the path named one.
func serveUI(w http.ResponseWriter, path string) bool {
	var body []byte
	var contentType string
	switch path {
	case "/":
		body, contentType = uiHTML, "text/html; charset=utf-8"
	case "/ui.css":
		body, contentType = uiCSS, "text/css; charset=utf-8"
	case "/ui.js":
		body, contentType = uiJS, "text/javascript; charset=utf-8"
	default:
		return false
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Security-Policy", uiContentSecurityPolicy)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	// The assets change with the binary and the pages are small, so a stale copy
	// is worth more trouble than a refetch.
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(body)
	return true
}
