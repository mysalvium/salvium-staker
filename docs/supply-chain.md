# Supply-chain verification

## Pinned inputs

- Ubuntu and Python bases use immutable multi-platform manifest digests.
- The official Salvium wallet/CLI version is explicit.
- Trusted x86-64 and ARM64 archive SHA-256 values are recorded under
  `checksums/` and were compared with the official release page.
- Every Python runtime package, including transitive packages, has an exact
  version.
- GitHub Actions use full commit SHAs.
- The Trivy scanner archive uses a fixed version and must match a hardcoded
  SHA-256 before it executes.

## Automatic download checks

The Docker build will not install a Salvium archive until its digest matches.
You can verify the host architecture separately:

```sh
./scripts/verify-downloads.sh
```

The weekly/manual GitHub workflow downloads and checks both Linux architectures:

```sh
./scripts/verify-downloads.sh --all
```

A new upstream version requires a reviewed change to the version, filenames,
checksums, and tests. A moving `latest` download is never executed.

## Security gate and SBOMs

After building:

```sh
./scripts/check-repo-safety.sh
./scripts/validate-hardening.sh .env.example
./scripts/security-scan.sh .env.example full
```

The scan checks repository secrets, configuration, dependencies, and both image
filesystems. It fails on a fixable critical image vulnerability and creates an
SPDX JSON SBOM for each image under `.security-reports/`. Reports and scanner
caches are ignored by Git.

Checksum publication and release files share an upstream channel, so this does
not provide independent publisher authentication. Review the official release
notes and signed provenance if Salvium adds it.
