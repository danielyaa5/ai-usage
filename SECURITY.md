# Security

The dashboard is meant for your own Mac and network. It answers only loopback, private-network and
Tailscale addresses, checks the Host header against this Mac's names and `allowed_hosts`, serves
read-only pages, and binds its telemetry receiver to loopback. Do not put it behind a public tunnel
or port forward: the page shows your projects' names, folders and usage.

It never reads credentials. The Antigravity limit reader holds that app's per-process CSRF token in
memory only and sends it only to that process's loopback port.

To report a vulnerability, use GitHub's private vulnerability reporting on this repository, or email
support@danielyakobian.com without exploit details and ask for a private channel. Please don't open a
public issue with logs, prompts, host names or account details.
