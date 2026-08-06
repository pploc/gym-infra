package tests

import (
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const kongURL = "http://localhost:8000"

type upstreamCapture struct {
	Method  string            `json:"method"`
	Path    string            `json:"path"`
	Headers map[string]string `json:"headers"`
}

func repoRoot(t *testing.T) string {
	t.Helper()
	// tests/ -> kong/
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Dir(wd)
}

func loadPrivateKey(t *testing.T, name string) *rsa.PrivateKey {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(repoRoot(t), "certs", name))
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		t.Fatalf("no PEM in %s", name)
	}
	key, err := x509.ParsePKCS1PrivateKey(block.Bytes)
	if err != nil {
		// openssl genrsa may emit PKCS#8
		k, err2 := x509.ParsePKCS8PrivateKey(block.Bytes)
		if err2 != nil {
			t.Fatalf("parse %s: pkcs1=%v pkcs8=%v", name, err, err2)
		}
		rk, ok := k.(*rsa.PrivateKey)
		if !ok {
			t.Fatalf("%s is not RSA", name)
		}
		return rk
	}
	return key
}

type tokenOpts struct {
	key               *rsa.PrivateKey
	kid               string
	alg               string
	iss               string
	aud               string
	sub               string
	role              string
	membershipStatus  string
	gymID             string
	expOffset         time.Duration
}

func makeToken(t *testing.T, o tokenOpts) string {
	t.Helper()
	if o.key == nil {
		o.key = loadPrivateKey(t, "fixture_rsa.key")
	}
	if o.kid == "" {
		o.kid = "current"
	}
	if o.alg == "" {
		o.alg = "RS256"
	}
	if o.iss == "" {
		o.iss = "gym-identifier"
	}
	if o.aud == "" {
		o.aud = "gym-api"
	}
	if o.sub == "" {
		o.sub = "user-123"
	}
	if o.role == "" {
		o.role = "CUSTOMER"
	}
	if o.membershipStatus == "" {
		o.membershipStatus = "NONE"
	}
	if o.gymID == "" {
		o.gymID = "gym-999"
	}
	if o.expOffset == 0 {
		o.expOffset = time.Hour
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"iss":               o.iss,
		"aud":               o.aud,
		"sub":               o.sub,
		"iat":               now.Unix(),
		"exp":               now.Add(o.expOffset).Unix(),
		"jti":               "test-jti-123",
		"role":              o.role,
		"membership_status": o.membershipStatus,
		"gym_id":            o.gymID,
	}
	tok := jwt.NewWithClaims(jwt.GetSigningMethod(o.alg), claims)
	tok.Header["kid"] = o.kid
	s, err := tok.SignedString(o.key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func sha256Hex(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func redisAddr() string {
	if v := os.Getenv("KONG_TEST_REDIS_ADDR"); v != "" {
		return v
	}
	// compose publishes kong redis as host 6380 (6379 often used by service redis).
	return "127.0.0.1:6380"
}

// Minimal RESP helpers — stdlib only; no redis client dependency.
func redisDo(cmd string, args ...string) (string, error) {
	conn, err := net.DialTimeout("tcp", redisAddr(), 2*time.Second)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	payload := fmt.Sprintf("*%d\r\n$%d\r\n%s\r\n", len(args)+1, len(cmd), cmd)
	for _, a := range args {
		payload += fmt.Sprintf("$%d\r\n%s\r\n", len(a), a)
	}
	if _, err := io.WriteString(conn, payload); err != nil {
		return "", err
	}
	buf := make([]byte, 256)
	n, err := conn.Read(buf)
	if err != nil {
		return "", err
	}
	return string(buf[:n]), nil
}

func redisSet(key, value string) error {
	resp, err := redisDo("SET", key, value)
	if err != nil {
		return err
	}
	if len(resp) == 0 || resp[0] == '-' {
		return fmt.Errorf("redis SET failed: %q", resp)
	}
	return nil
}

func redisDel(key string) error {
	_, err := redisDo("DEL", key)
	return err
}

func doRequest(t *testing.T, method, path string, headers map[string]string, body io.Reader) (int, upstreamCapture, []byte) {
	t.Helper()
	req, err := http.NewRequest(method, kongURL+path, body)
	if err != nil {
		t.Fatal(err)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request %s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	var cap upstreamCapture
	_ = json.Unmarshal(raw, &cap)
	return resp.StatusCode, cap, raw
}

func headerCI(h map[string]string, name string) string {
	// mock upstream uses BaseHTTPRequestHandler Title-Case for some headers
	if v, ok := h[name]; ok {
		return v
	}
	// try common casings
	for k, v := range h {
		if equalFold(k, name) {
			return v
		}
	}
	return ""
}

func equalFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}

func TestPublicRoutesPassWithoutTokenAndStripHeaders(t *testing.T) {
	status, cap, _ := doRequest(t, http.MethodPost, "/api/v1/auth/login", map[string]string{
		"x-user-id":            "hacker-123",
		"x-user-role":          "SUPER_ADMIN",
		"x-gym-id":             "hacker-gym",
		"x-membership-status":  "ACTIVE",
		"Content-Type":         "application/json",
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
	for _, h := range []string{"x-user-id", "x-user-role", "x-gym-id", "x-membership-status"} {
		if v := headerCI(cap.Headers, h); v != "" {
			t.Fatalf("public route leaked %s=%q", h, v)
		}
	}
}

func TestProtectedRouteRejectsMissingToken(t *testing.T) {
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", nil, nil)
	if status != 401 {
		t.Fatalf("status=%d want 401", status)
	}
}

func TestProtectedRouteAcceptsValidTokenAndInjectsHeaders(t *testing.T) {
	tok := makeToken(t, tokenOpts{sub: "user-456", role: "CUSTOMER", membershipStatus: "NONE", gymID: "gym-1"})
	status, cap, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
	if got := headerCI(cap.Headers, "x-user-id"); got != "user-456" {
		t.Fatalf("x-user-id=%q", got)
	}
	if got := headerCI(cap.Headers, "x-user-role"); got != "CUSTOMER" {
		t.Fatalf("x-user-role=%q", got)
	}
	if got := headerCI(cap.Headers, "x-gym-id"); got != "gym-1" {
		t.Fatalf("x-gym-id=%q", got)
	}
	if got := headerCI(cap.Headers, "x-membership-status"); got != "NONE" {
		t.Fatalf("x-membership-status=%q", got)
	}
}

func TestProtectedRouteStripsSpoofedHeadersAndInjectsClaims(t *testing.T) {
	tok := makeToken(t, tokenOpts{sub: "user-real", role: "CUSTOMER", membershipStatus: "NONE"})
	status, cap, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization":        "Bearer " + tok,
		"x-user-id":            "spoofed-user",
		"x-user-role":          "SUPER_ADMIN",
		"x-membership-status":  "ACTIVE",
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
	if got := headerCI(cap.Headers, "x-user-id"); got != "user-real" {
		t.Fatalf("x-user-id=%q", got)
	}
	if got := headerCI(cap.Headers, "x-user-role"); got != "CUSTOMER" {
		t.Fatalf("x-user-role=%q", got)
	}
	if got := headerCI(cap.Headers, "x-membership-status"); got != "NONE" {
		t.Fatalf("x-membership-status=%q", got)
	}
}

func TestKeyRotationPreviousKeyAccepted(t *testing.T) {
	prev := loadPrivateKey(t, "fixture_rsa_prev.key")
	tok := makeToken(t, tokenOpts{key: prev, kid: "previous", sub: "user-prev"})
	status, cap, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
	if got := headerCI(cap.Headers, "x-user-id"); got != "user-prev" {
		t.Fatalf("x-user-id=%q", got)
	}
}

func TestInvalidSignatureRejected(t *testing.T) {
	prev := loadPrivateKey(t, "fixture_rsa_prev.key")
	// sign with prev key but claim current kid
	tok := makeToken(t, tokenOpts{key: prev, kid: "current"})
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 401 {
		t.Fatalf("status=%d want 401", status)
	}
}

func TestUnknownKidRejected(t *testing.T) {
	tok := makeToken(t, tokenOpts{kid: "unknown-kid"})
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 401 {
		t.Fatalf("status=%d want 401", status)
	}
}

func TestInvalidIssuerRejected(t *testing.T) {
	tok := makeToken(t, tokenOpts{iss: "bad-issuer"})
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 401 {
		t.Fatalf("status=%d want 401", status)
	}
}

func TestInvalidAudienceRejected(t *testing.T) {
	tok := makeToken(t, tokenOpts{aud: "bad-audience"})
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 401 {
		t.Fatalf("status=%d want 401", status)
	}
}

func TestExpiredTokenRejected(t *testing.T) {
	tok := makeToken(t, tokenOpts{expOffset: -10 * time.Second})
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 401 {
		t.Fatalf("status=%d want 401", status)
	}
}

func TestNoneStatusAcceptedOnOrdinaryProtectedRoute(t *testing.T) {
	tok := makeToken(t, tokenOpts{role: "CUSTOMER", membershipStatus: "NONE"})
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/members/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
}

func TestMembershipGatedRouteRequiresActiveStatus(t *testing.T) {
	for _, st := range []string{"NONE", "EXPIRED"} {
		tok := makeToken(t, tokenOpts{role: "CUSTOMER", membershipStatus: st})
		status, _, _ := doRequest(t, http.MethodGet, "/api/v1/memberships/booking", map[string]string{
			"Authorization": "Bearer " + tok,
		}, nil)
		if status != 403 {
			t.Fatalf("status=%d for %s want 403", status, st)
		}
	}
	tok := makeToken(t, tokenOpts{role: "CUSTOMER", membershipStatus: "ACTIVE"})
	status, cap, _ := doRequest(t, http.MethodGet, "/api/v1/memberships/booking", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
	if got := headerCI(cap.Headers, "x-membership-status"); got != "ACTIVE" {
		t.Fatalf("x-membership-status=%q", got)
	}
}

func TestTraceparentPreserved(t *testing.T) {
	tok := makeToken(t, tokenOpts{})
	want := "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
	status, cap, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
		"traceparent":   want,
		"x-trace-id":    "legacy-trace-123",
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
	if got := headerCI(cap.Headers, "traceparent"); got != want {
		t.Fatalf("traceparent=%q want %q", got, want)
	}
}

func TestCustomerRoleAcceptedMemberRoleRejected(t *testing.T) {
	tok := makeToken(t, tokenOpts{role: "CUSTOMER"})
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 200 {
		t.Fatalf("CUSTOMER status=%d want 200", status)
	}

	// MEMBER is not a valid end-user role (CUSTOMER replaced it)
	tok = makeToken(t, tokenOpts{role: "MEMBER"})
	status, _, _ = doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 403 {
		t.Fatalf("MEMBER status=%d want 403", status)
	}
}

func TestAlgorithmNoneRejected(t *testing.T) {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT","kid":"current"}`))
	now := time.Now().Unix()
	payloadObj := map[string]any{
		"iss":               "gym-identifier",
		"aud":               "gym-api",
		"sub":               "user-none",
		"iat":               now,
		"exp":               now + 3600,
		"jti":               "none-jti",
		"role":              "CUSTOMER",
		"membership_status": "NONE",
		"gym_id":            "gym-1",
	}
	pb, _ := json.Marshal(payloadObj)
	payload := base64.RawURLEncoding.EncodeToString(pb)
	tok := header + "." + payload + "."
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 401 {
		t.Fatalf("status=%d want 401", status)
	}
}

func TestInternalMembershipRPCUnreachable(t *testing.T) {
	status, _, _ := doRequest(t, http.MethodPost, "/member.v1.MemberService/GetMembershipStatusByUserId", nil, nil)
	if status != 404 {
		t.Fatalf("status=%d want 404", status)
	}
}

func TestBlacklistedAccessTokenRejected(t *testing.T) {
	tok := makeToken(t, tokenOpts{sub: "user-blacklisted"})
	// given: Identifier logout stores blacklist:<sha256_hex(raw_token)>
	sum := sha256Hex(tok)
	if err := redisSet("blacklist:"+sum, "1"); err != nil {
		t.Fatalf("seed blacklist: %v", err)
	}
	t.Cleanup(func() { _ = redisDel("blacklist:" + sum) })

	// when
	status, _, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)

	// then
	if status != 401 {
		t.Fatalf("status=%d want 401 for blacklisted token", status)
	}
}

func TestNonBlacklistedTokenStillAccepted(t *testing.T) {
	tok := makeToken(t, tokenOpts{sub: "user-clean"})
	status, cap, _ := doRequest(t, http.MethodGet, "/api/v1/users/me", map[string]string{
		"Authorization": "Bearer " + tok,
	}, nil)
	if status != 200 {
		t.Fatalf("status=%d want 200", status)
	}
	if got := headerCI(cap.Headers, "x-user-id"); got != "user-clean" {
		t.Fatalf("x-user-id=%q", got)
	}
}
