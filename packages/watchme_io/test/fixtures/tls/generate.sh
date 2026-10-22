#!/bin/sh
# Regenerates the TEST-ONLY TLS fixtures used by watchme_io's loopback tests.
# These keys are public and must never be trusted outside the test suite.
set -eu
cd "$(dirname "$0")"
DAYS=36500

ext() { printf '%s\n' "$1" > "$2"; }

# Test CA.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout ca.key -out ca.pem -days $DAYS -subj "/CN=watchme test CA (TEST ONLY)" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"

# Server certificate for 127.0.0.1 signed by the test CA.
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout server.key -out server.csr -subj "/CN=127.0.0.1 (TEST ONLY)"
ext "subjectAltName=IP:127.0.0.1,DNS:localhost
basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth" server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out server.pem -days $DAYS -extfile server.ext

# Self-signed server certificate for 127.0.0.1 (a TV-style certificate).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout selfsigned.key -out selfsigned.pem -days $DAYS \
  -subj "/CN=watchme self-signed TV (TEST ONLY)" \
  -addext "subjectAltName=IP:127.0.0.1"

# Client certificate signed by the test CA, for mutual TLS.
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout client.key -out client.csr -subj "/CN=watchme test client (TEST ONLY)"
ext "basicConstraints=CA:FALSE
extendedKeyUsage=clientAuth" client.ext
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -out client.pem -days $DAYS -extfile client.ext

rm -f server.csr client.csr server.ext client.ext ca.srl
