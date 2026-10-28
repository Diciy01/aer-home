These public keys and self-signed certificates are **TEST ONLY**. They are
used by `files_client_tls_test.dart` on an ephemeral IPv4 loopback listener.
Never use them for a deployed Core, Gateway or host.

The test adds the loopback certificate to Dart's process-local default TLS
context to reproduce the previously bypassed callback. It never changes an
OS certificate store. The other certificate remains untrusted.

Generated with OpenSSL `req -x509 -newkey rsa:2048 -nodes -days 3650`,
`subjectAltName=IP:127.0.0.1`, on 2026-10-28.
