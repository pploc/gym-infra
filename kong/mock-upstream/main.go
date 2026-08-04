package main

import (
	"encoding/json"
	"log"
	"net/http"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		headers := make(map[string]string, len(r.Header))
		for k, vs := range r.Header {
			if len(vs) > 0 {
				headers[k] = vs[0]
			}
		}
		body, err := json.Marshal(map[string]any{
			"method":  r.Method,
			"path":    r.URL.RequestURI(),
			"headers": headers,
		})
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	})

	addr := ":8080"
	log.Printf("Mock upstream running on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}
