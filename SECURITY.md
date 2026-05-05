# Security Policy

StatusPulse is designed to keep secrets out of source control and to harden the public edge as much as possible for a small AWS deployment.

## Secrets Handling

- Do not commit `.env` files.
- Keep the sample values in `.env.example`.
- Use GitHub Actions secrets for deploy-time values such as notification webhooks.
- Let Terraform or EC2 user data create the server-side `.env` file.

## Network Exposure

- Only ports 80 and 443 are publicly exposed on the AWS host.
- The runtime uses Caddy for TLS termination and reverse proxying.
- SSH is not required for the default SSM-based deployment path.

## Application Controls

- Requests are rate-limited in `app/main.py`.
- `/health` is exempt so monitoring can keep working.
- Database and Redis access are only available inside the Docker network.

## Edge Security Headers

Caddy sets the following headers:

- `Strict-Transport-Security`
- `X-Content-Type-Options`
- `X-Frame-Options`
- `X-XSS-Protection`
- `Referrer-Policy`

## Scanning

The CI workflow should include:

- `ruff` for Python linting
- `hadolint` for the Dockerfile
- `Trivy` filesystem scanning
- `Trivy` image scanning

Example local commands:

```bash
trivy fs --scanners vuln,secret .
trivy image ghcr.io/ManojSelf/statuspulse:latest
```

## Backups and Recovery

- Back up PostgreSQL regularly with `scripts/backup.sh`.
- Keep a tested restore procedure before calling the setup production-ready.
- Protect backup buckets or archives with least-privilege access.

## Incident Response

If you suspect compromise:

1. Revoke the deploy secrets.
2. Rotate database and Redis passwords.
3. Redeploy a clean image from CI.
4. Review CloudWatch, container, and application logs.
5. Rebuild the EC2 host if you cannot trust it anymore.
