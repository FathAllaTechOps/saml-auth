# saml-auth

[![Release Workflow](https://github.com/FathAllaTechOps/saml-auth/actions/workflows/release.yml/badge.svg?branch=main&event=workflow_run)](https://github.com/FathAllaTechOps/saml-auth/actions/workflows/release.yml)

Two CLI tools for AWS authentication and EKS cluster IP whitelisting.

| Tool | Purpose |
| --- | --- |
| `saml` | Authenticate to AWS accounts via SAML (saml2aws) and update kubeconfigs |
| `eks` | Whitelist your current external IP on EKS cluster `publicAccessCidrs` |

---

## Prerequisites

- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- [jq](https://stedolan.github.io/jq/)
- `dig` (comes with `bind` / `bind-tools` — pre-installed on macOS)
- For `saml`: [saml2aws](https://github.com/Versent/saml2aws)

---

## Installation

### via Homebrew (recommended)

```bash
brew tap FathAllaTechOps/saml-auth
brew install saml-auth
```

### Manual install

```bash
curl -sSL https://github.com/FathAllaTechOps/saml-auth/archive/refs/heads/main.tar.gz | tar -xz
sudo cp saml-auth-main/bin/saml.sh /usr/local/bin/saml
sudo cp saml-auth-main/bin/eks.sh  /usr/local/bin/eks
sudo chmod +x /usr/local/bin/saml /usr/local/bin/eks
```

---

## Upgrade

### via Homebrew

```bash
brew update && brew upgrade saml-auth
```

### Manual upgrade

Re-run the manual install steps above with the latest release tarball:

```bash
VERSION="v8.0.0"   # replace with the latest version
curl -sSL "https://github.com/FathAllaTechOps/saml-auth/archive/${VERSION}.tar.gz" | tar -xz
sudo cp "saml-auth-${VERSION#v}/bin/saml.sh" /usr/local/bin/saml
sudo cp "saml-auth-${VERSION#v}/bin/eks.sh"  /usr/local/bin/eks
sudo chmod +x /usr/local/bin/saml /usr/local/bin/eks
```

---

## Usage

### `saml` — AWS SAML Authentication

**First-time setup** — configure your AWS profiles:

```bash
saml config
```

**Authenticate and update kubeconfigs:**

```bash
saml
```

You will be prompted for your SSO email and password. The script will:

1. Authenticate each selected profile via `saml2aws`
2. Update `~/.kube/config` with all EKS clusters across `eu-west-1` and `eu-central-1`
3. Optionally run `eks` to whitelist your IP on production clusters

**Options:**

```text
saml config     Configure AWS profiles
saml --help     Show help
saml --version  Show version
```

---

### `eks` — EKS IP Whitelisting

Adds your current external IP as a `/32` CIDR to EKS cluster `publicAccessCidrs`.

Supports both **AWS SSO** profiles (`~/.aws/config`) and **static credential** profiles (`~/.aws/credentials`).

```bash
eks
```

You will be prompted to select:

1. AWS region (`eu-west-1`, `eu-central-1`, `us-east-2`, `us-east-1`)
2. AWS profile — SSO profiles are tagged `[sso]`, credential profiles tagged `[creds]`
3. Which clusters to update

If your SSO session is expired, the script automatically triggers `aws sso login` before proceeding.

```text
eks --help      Show help
```

> **Note:** The IP whitelisting step is only needed for **production accounts**. Lower environments are open to `0.0.0.0/0` by default.

---

## Release process

Releases are published via the [Release Workflow](https://github.com/FathAllaTechOps/saml-auth/actions/workflows/release.yml) GitHub Action, triggered manually.

**Steps:**

1. Merge all changes into `main`
2. Go to **Actions → Release Workflow → Run workflow**
3. Enter the version in `vX.Y.Z` format (e.g. `v8.1.0`)
4. Click **Run workflow**

The workflow will:

1. Validate the version format (`vX.Y.Z`)
2. Run ShellCheck on all `.sh` files — the release is blocked if any check fails
3. Create a GitHub release tagged with the version
4. Upload `bin/saml.sh` and `bin/eks.sh` as release assets
5. Compute and print the SHA256 checksum of the source tarball (needed to update the Homebrew formula)

**Versioning convention:** follow [semver](https://semver.org/).

- Bump **patch** (`v8.0.x`) for bug fixes
- Bump **minor** (`v8.x.0`) for new features or backward-compatible changes
- Bump **major** (`vx.0.0`) for breaking changes

---

## Configuration files

| Path                                    | Purpose                             |
| --------------------------------------- | ----------------------------------- |
| `~/.saml-auth/saml_profile.config`      | Profiles saved by `saml config`     |
| `~/.aws/config`                         | AWS SSO profiles                    |
| `~/.aws/credentials`                    | Static credential profiles (legacy) |
| `~/.saml2aws`                           | saml2aws configuration              |
