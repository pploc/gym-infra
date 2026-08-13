package main

import (
	"bytes"
	"context"
	"net/http/httptest"
	"testing"

	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestGivenTrustedAndForgedHeaders_WhenBuildingMetadata_ThenOnlyApprovedSingleValuesForward(t *testing.T) {
	// given
	request := httptest.NewRequest("GET", "/api/v1/members/member-1", nil)
	request.Header.Set(headerUserID, " user-1 ")
	request.Header.Set(headerUserRole, "CUSTOMER")
	request.Header.Set("Traceparent", "00-trace-parent")
	request.Header.Set("Tracestate", "vendor=value")
	request.Header.Set("X-Gym-Id", "forged-gym")
	request.Header.Set("X-Membership-Status", "ACTIVE")
	request.Header.Set("X-Trace-Id", "forged-trace")
	request.Header.Set("Grpc-Metadata-X-User-Id", "forged-user")

	// when
	metadata := outgoingMetadata(request.Context(), request)

	// then
	if got := metadata.Get(headerUserID); len(got) != 1 || got[0] != "user-1" {
		t.Fatalf("x-user-id = %v", got)
	}
	if got := metadata.Get(headerUserRole); len(got) != 1 || got[0] != "CUSTOMER" {
		t.Fatalf("x-user-role = %v", got)
	}
	if got := metadata.Get("traceparent"); len(got) != 1 || got[0] != "00-trace-parent" {
		t.Fatalf("traceparent = %v", got)
	}
	if got := metadata.Get("tracestate"); len(got) != 1 || got[0] != "vendor=value" {
		t.Fatalf("tracestate = %v", got)
	}
	for _, forbidden := range []string{"x-gym-id", "x-membership-status", "x-trace-id", "grpc-metadata-x-user-id"} {
		if got := metadata.Get(forbidden); len(got) != 0 {
			t.Fatalf("forbidden %s = %v", forbidden, got)
		}
	}
}

func TestGivenDuplicateOrBlankTrustedHeaders_WhenBuildingMetadata_ThenTheyDoNotForward(t *testing.T) {
	// given
	request := httptest.NewRequest("GET", "/api/v1/members/member-1", nil)
	request.Header.Add(headerUserID, "user-1")
	request.Header.Add(headerUserID, "forged-user")
	request.Header.Set(headerUserRole, " ")

	// when
	metadata := outgoingMetadata(request.Context(), request)

	// then
	if len(metadata.Get(headerUserID)) != 0 || len(metadata.Get(headerUserRole)) != 0 {
		t.Fatalf("metadata = %v", metadata)
	}
}

func TestGivenHeaderName_WhenMatchingIncomingMetadata_ThenGatewayRejectsIt(t *testing.T) {
	// given / when
	name, ok := rejectIncomingHeader("Grpc-Metadata-X-User-Id")

	// then
	if ok || name != "" {
		t.Fatalf("header matcher = %q, %t", name, ok)
	}
}

func TestGivenUpstreamErrorCodeTrailer_WhenHandlingError_ThenPromotesHeaderAndKeepsDefaultBody(t *testing.T) {
	// given
	request := httptest.NewRequest("GET", "/api/v1/plans/missing", nil)
	writer := httptest.NewRecorder()
	mux := runtime.NewServeMux()
	marshaler := &runtime.JSONPb{}
	serverMetadata := runtime.ServerMetadata{TrailerMD: metadata.Pairs(headerError, "PLAN_NOT_FOUND")}
	contextWithMetadata := runtime.NewServerMetadataContext(context.Background(), serverMetadata)

	// when
	promoteErrorCode(contextWithMetadata, mux, marshaler, writer, request, status.Error(codes.NotFound, "missing"))

	// then
	if got := writer.Header().Get(headerError); got != "PLAN_NOT_FOUND" {
		t.Fatalf("x-error-code = %q", got)
	}
	if got := writer.Code; got != 404 {
		t.Fatalf("status = %d", got)
	}
	if !bytes.Contains(writer.Body.Bytes(), []byte(`"code":5`)) {
		t.Fatalf("default body = %s", writer.Body.String())
	}
}

func TestGivenErrorCode_WhenCheckingHeaderSafety_ThenOnlySingleLineValuePasses(t *testing.T) {
	// given / when / then
	if !validHeaderValue("MEMBER_NOT_FOUND") {
		t.Fatal("expected safe error code")
	}
	if validHeaderValue("bad\r\nX-Forged: true") || validHeaderValue("") {
		t.Fatal("expected unsafe error code rejection")
	}
}
