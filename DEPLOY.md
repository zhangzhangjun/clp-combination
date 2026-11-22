# One-command native deployment

On a CentOS/RHEL Linux server with systemd, install the prebuilt Go binary and
integrated management frontend with:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zhangzhangjun/clp-combination/main/install.sh)
```

The installer finds the latest GitHub Release, downloads the matching
`linux/amd64` or `linux/arm64` package, verifies its SHA256 checksum, installs a
systemd service, and starts it.
Docker, Python, uv, Playwright, Chromium and Xvfb are not required. CLIProxyAPI
serves the OpenAI and Anthropic compatible endpoints on port `8317`, for example:

```text
POST http://server:8317/anthropic/claude/v1/messages
```

On a fresh install, the installer generates a client API key and management key
and prints them once. Save both.

To build the downloadable CentOS-compatible release on Windows, run
`buliu\build-release.bat` (defaults to amd64; pass `arm64` for ARM servers).
The stable archives and checksums are written to `dist/`, while versioned
archives are attached to GitHub Releases. The Windows BAT also attempts to
publish the same release and installer files to Gitee after GitHub succeeds;
Gitee mirror failures are reported without blocking the GitHub release.
Configure write access for both hosts before publishing, and verify that the
raw GitHub `install.sh` URL returns HTTP 200 before deployment.

The server uses the embedded model catalog by default. The SQLite request-log
index keeps at most 100 detailed rows by default; older rows remain represented
in aggregate usage tables. Change `request-log-max-records` in `config.yaml` to
configure this limit; use `0` to disable it.
