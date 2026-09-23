# Security review (read-only)

Review the repository and report findings. **Do not modify any file.**

Cover:

- secrets in tracked files, commit messages, or examples
- command injection, unsafe expansion, unquoted variables in shell
- SSRF and egress controls, especially the mesh-range check
- path traversal and unsafe file handling
- container privilege, capabilities, socket exposure
- network exposure: binds, proxy routes, allowlists
- credential handling in logs and error paths
- dependency and image pinning
- backup credential separation and encryption

For each finding give: severity, file and line, why it matters, and a suggested fix.
Map to OWASP Top 10 where applicable. Distinguish confirmed findings from suspicions.
