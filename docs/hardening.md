# Server Hardening Beyond Fail2ban

## 1. Patch and Package Hygiene
- Keep the host OS, Podman, container images, Node.js runtimes, and npm packages patched.
- Automate host OS updates via **`upgrade-host-packages-weekly.sh`** / `manage-weekly-maintenance.sh install` (Sunday `dnf upgrade`; reboot when `/var/lib/infra/reboot-required` appears, or set `AUTO_REBOOT=1`).
- Automate Grafana/Loki image rebuilds via **`update-monitoring-images-weekly.sh`** (Sunday; skips unless local/upstream images are at least **3 days** old). Bumping pinned versions in `grafanaloki-app/.env` remains manual. Routinely review `npm audit` output before applying application dependency fixes.

## 3. Harden TLS and Reverse Proxies
- Configure Nginx to set security headers: `Strict-Transport-Security`, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`, and a tailored `Content-Security-Policy`.
- Add rate limiting, request-size limits, and upstream health checks to throttle abusive clients.

## 4. Strengthen Container Security
- Scan and sign images (e.g., Trivy, cosign) before promotion to production registries.

## 5. Secure Node.js and React Applications
- Disable the `X-Powered-By` header and use middleware such as Helmet for HTTP security headers.
- Validate and sanitize all inputs, escape output, and log validation failures without leaking sensitive data.
- Store secrets in environment vars or a dedicated secrets manager; avoid embedding them in source or images.
- Use dependency update tooling (Renovate, Dependabot) to surface vulnerable packages early.

## 6. Tighten Host-Level Controls
- Enforce SSH key authentication, disable password logins, and limit sudo privileges to the minimum required. Apply on each host: `sudo ./harden-server-oneoff.sh` or `sudo ./apply-security-improvements-oneoff.sh` (see `~/infra-app/maintenance-status.md` for state).
- Enable auditing (auditd or enhanced journald logging) and forward logs to a central collector for tamper resistance.
- Rotate and archive logs securely, and monitor for suspicious authentication attempts or privilege escalation.

## 7. Monitor Runtime Health and security
- Expand beyond Fail2ban with resource monitoring (node_exporter, Grafana alerts) and anomaly detection for CPU, memory, and traffic spikes.
- Configure health probes for each service and alert on repeated failures or container restarts.
- Track application metrics and 4xx/5xx error rates to detect probing or exploitation attempts.
