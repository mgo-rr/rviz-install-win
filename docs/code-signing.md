# Code signing (internal certificate)

Release MSIs are Authenticode-signed with an internal, self-signed
certificate of the Relay Robotics Robo Care Team. It is not issued by a public
certificate authority, so Windows only trusts it on PCs where the public
certificate below has been installed. Install it on team PCs (by IT, ideally)
before the team installs the MSI.

| | |
|---|---|
| Subject | `CN=Relay Robotics Robo Care Code Signing, O=Relay Robotics, E=support@relayrobotics.com` |
| Valid | 2026-10-06 to 2031-10-06 |
| SHA-1 thumbprint | `F8CB7F5A10EBE5DDC4F2CDCBCE3598E0FF97899F` |
| SHA-256 | `EFD9661E53539D118DA7BAC87D2A8B27596B593C73545FE55FAE4BFDE5F8ED57` |
| Usage | Code signing only (`CA:FALSE`, key usage *digital signature*, EKU *code signing*): it cannot issue other certificates or act as a TLS server certificate |
| File | [`certs/robo-care-code-signing.cer`](../certs/robo-care-code-signing.cer) (DER) |

Check the thumbprint of the file you deploy against this table. The
repository is public, so get the table from a source you trust (this file at a
known commit, or from the Robo Care Team directly).

## What it changes, and what it does not

With the certificate installed:

- The UAC prompt names **Relay Robotics Robo Care Code Signing** as the
  verified publisher instead of *Unknown publisher*.
- The MSI's *Properties > Digital Signatures* tab shows a valid signature, so
  a modified or corrupted MSI is detected.

**SmartScreen ("Windows protected your PC") may still appear** for an MSI
downloaded with a browser. SmartScreen decides by Microsoft's download
reputation, which an internal certificate does not have. To avoid it:

- Deploy the MSI itself with Intune or Group Policy (no browser download, no
  SmartScreen check). Recommended for team PCs.
- Or, for a manual download: *More info > Run anyway*, or right-click the MSI >
  *Properties* > tick **Unblock** > OK before opening it.

## Installing the certificate

The certificate must go into two machine stores:

- **Trusted Root Certification Authorities** (`Root`): makes the chain valid.
- **Trusted Publishers** (`TrustedPublisher`): marks the publisher as trusted.

### Intune

Devices > Configuration > Create > Windows 10 and later > Templates >
**Trusted certificate**: upload `robo-care-code-signing.cer`, destination
store *Computer certificate store - Root*. Code signing trust in Trusted
Publishers needs a second step, for example a PowerShell platform script
(run as system) with the command from the *One PC* section below.

### Group Policy

Computer Configuration > Policies > Windows Settings > Security Settings >
Public Key Policies:

1. **Trusted Root Certification Authorities** > Import > the `.cer` file.
2. **Trusted Publishers** > Import > the same file.

### One PC (administrator PowerShell)

```powershell
$cer = "$env:USERPROFILE\Downloads\robo-care-code-signing.cer"
(Get-PfxCertificate $cer).Thumbprint   # must be F8CB7F5A10EBE5DDC4F2CDCBCE3598E0FF97899F
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

Check an MSI:

```powershell
Get-AuthenticodeSignature .\RVizNoetic-*.msi | Format-List Status, SignerCertificate, TimeStamperCertificate
```

`Status` is `Valid` on a PC with the certificate and `UnknownError` (untrusted
root) on one without it; the MSI installs either way.

To remove it: `certlm.msc`, delete the certificate from both stores.

## How CI signs

The `build` job in `.github/workflows/ci.yml` reads two repository secrets:

| Secret | Content |
|---|---|
| `SIGN_PFX_BASE64` | the PFX (certificate + private key), base64 |
| `SIGN_PFX_PASSWORD` | the PFX password |

It checks that the PFX matches `certs/robo-care-code-signing.cer`, trusts that
certificate on the runner, and passes `-SignPfx` to `build-rviz-msi.ps1`. The
msi step signs with SHA-256 and an RFC 3161 timestamp
(`SignTimestampUrl`, DigiCert), runs `signtool verify /pa`, and only then
writes the `.sha256`. The timestamp keeps signatures valid after the
certificate expires. A `v*` tag fails if the secrets are missing, so a
release is never unsigned. Builds from forks or without secrets stay unsigned.

## The private key

Whoever holds the private key can sign software that team PCs trust, so:

- It exists only in the GitHub secrets and in one backup held by the Robo Care
  Team. Never commit it.
- If it leaks: remove the certificate from team PCs (Intune / GPO), delete the
  secrets, and make a new certificate (below).

## Renewing or replacing the certificate

Before 2031-10-06, or after a leak (Linux or WSL, OpenSSL 3):

```bash
cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Relay Robotics Robo Care Code Signing
O = Relay Robotics
emailAddress = support@relayrobotics.com
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF
umask 077
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out key.pem
openssl req -new -x509 -key key.pem -config cert.cnf -sha256 -days 1826 -out cert.pem
openssl rand -base64 30 | tr -d '\n' > pfx-password.txt
openssl pkcs12 -export -inkey key.pem -in cert.pem -name "Relay Robotics Robo Care Code Signing" \
  -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 -passout file:pfx-password.txt -out signing.pfx
openssl x509 -in cert.pem -outform DER -out robo-care-code-signing.cer
gh secret set SIGN_PFX_BASE64 --repo mgo-rr/rviz-install-win < <(base64 -w0 signing.pfx)
gh secret set SIGN_PFX_PASSWORD --repo mgo-rr/rviz-install-win < pfx-password.txt
```

Then replace `certs/robo-care-code-signing.cer`, update the table at the top,
and deploy the new `.cer` to team PCs before the next release.
