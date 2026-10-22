// TEST-ONLY key material for the Fire TV simulator. These self-signed
// certificates and private keys are public, committed on purpose, and must
// never be used for anything but loopback tests. Generated with:
//
//   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
//     -nodes -days 36500 -subj "/CN=watchme Fire TV simulator TEST ONLY (<n>)" \
//     -addext "subjectAltName=IP:127.0.0.1,IP:::1,DNS:localhost"
//   openssl pkcs8 -topk8 -nocrypt   # key converted to PKCS#8

/// Certificate (PEM) of the `primary` simulator identity.
const String primaryCertificatePem = '''
-----BEGIN CERTIFICATE-----
MIIB9jCCAZygAwIBAgIUcfZ55lpFSvCT/rzMEryCodVYXeEwCgYIKoZIzj0EAwIw
ODE2MDQGA1UEAwwtd2F0Y2htZSBGaXJlIFRWIHNpbXVsYXRvciBURVNUIE9OTFkg
KHByaW1hcnkpMCAXDTI2MTAyMTE1NTczOVoYDzIxMjYwOTI3MTU1NzM5WjA4MTYw
NAYDVQQDDC13YXRjaG1lIEZpcmUgVFYgc2ltdWxhdG9yIFRFU1QgT05MWSAocHJp
bWFyeSkwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATRIicJLJvNjAjbaX1ku+Pm
TN+Q6hTnvmemKl2n10GzA24qgVEw5C5rY7B1P0mIKyYbB62Loel1zVfcMWcu1HYX
o4GBMH8wHQYDVR0OBBYEFMlNQxCISp4s0aYmNe3X7nyyu3WjMB8GA1UdIwQYMBaA
FMlNQxCISp4s0aYmNe3X7nyyu3WjMA8GA1UdEwEB/wQFMAMBAf8wLAYDVR0RBCUw
I4cEfwAAAYcQAAAAAAAAAAAAAAAAAAAAAYIJbG9jYWxob3N0MAoGCCqGSM49BAMC
A0gAMEUCIQCHk0gQRG4P+nZrZuCde2+Nr5DPtSUipl1a+AlzlTDtKwIgKvQ2H4+6
1SD7Imuvun+JfAlmODXXJbLBkbZcA+59NcM=
-----END CERTIFICATE-----
''';

/// Private key (PKCS#8 PEM) of the `primary` simulator identity.
const String primaryPrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgPNGfq0lBhR1WP3Jo
C8PvKDiUMK+2/6MTGDYnnKPxRyGhRANCAATRIicJLJvNjAjbaX1ku+PmTN+Q6hTn
vmemKl2n10GzA24qgVEw5C5rY7B1P0mIKyYbB62Loel1zVfcMWcu1HYX
-----END PRIVATE KEY-----
''';

/// Certificate (PEM) of the `alternate` simulator identity.
const String alternateCertificatePem = '''
-----BEGIN CERTIFICATE-----
MIIB+jCCAaCgAwIBAgIUc9m3eZ4B/rsWzllw8NUebjKmXtMwCgYIKoZIzj0EAwIw
OjE4MDYGA1UEAwwvd2F0Y2htZSBGaXJlIFRWIHNpbXVsYXRvciBURVNUIE9OTFkg
KGFsdGVybmF0ZSkwIBcNMjYxMDIxMTU1NzM5WhgPMjEyNjA5MjcxNTU3MzlaMDox
ODA2BgNVBAMML3dhdGNobWUgRmlyZSBUViBzaW11bGF0b3IgVEVTVCBPTkxZIChh
bHRlcm5hdGUpMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEGmkO5UqrSk5a9Ob+
YJjZi2R/XyVgiQnZnTrRTwvRN+K76CHXB/cAy0ATV4117GrnEFsel3S0Q227And0
FvBPUKOBgTB/MB0GA1UdDgQWBBS52DB7iuM3pfHV65sohg/oDPLosDAfBgNVHSME
GDAWgBS52DB7iuM3pfHV65sohg/oDPLosDAPBgNVHRMBAf8EBTADAQH/MCwGA1Ud
EQQlMCOHBH8AAAGHEAAAAAAAAAAAAAAAAAAAAAGCCWxvY2FsaG9zdDAKBggqhkjO
PQQDAgNIADBFAiEA0B7xiuLfg9Wh0fxfwrRaDOUiy3mb05BBlBO20BEOOB0CIAdF
qdogLk6KbFCaW/sQYIxfhOHtkOlDNYK0xFd538Li
-----END CERTIFICATE-----
''';

/// Private key (PKCS#8 PEM) of the `alternate` simulator identity.
const String alternatePrivateKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcHCwmVywZmL11gfd
lgcB/m8Igqgz6mMRZDoSngUt+lyhRANCAAQaaQ7lSqtKTlr05v5gmNmLZH9fJWCJ
CdmdOtFPC9E34rvoIdcH9wDLQBNXjXXsaucQWx6XdLRDbbsCd3QW8E9Q
-----END PRIVATE KEY-----
''';
