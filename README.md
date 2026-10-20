# LOGCENTER.R4X

`LOGCENTER.R4X` is an independent R4OS application implemented in Zig.

## Package

- Version: `0.1.7`
- Image target: `/R4OS/SOFTWARE/DESKTOP/LOGCENTER.R4X`
- Image scope: `full`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Parallel instances and export

Normal background instances declare `runtime.parallel=owned-v1`. Each instance
keeps one GUI producer and its own query, buffers and save policy. Console
`/SOURCE=`, `/MIN=`, `/SEARCH=` and `/OUT=` selections also apply to the GUI.

An export captures one complete, bounded, revision-stable non-kernel log view.
It formats private process buffers, then publishes through the SDK atomic save
policy. Concurrent instances cannot interleave file pages; a successful commit
replaces the complete target. Failure does not fall back to truncating the
published file. An unconfirmed replacement retains its complete temporary
copies and reports that state. Kernel logs remain exclusive to Spectra.

`/SELFTEST` includes a global LOGSVC stop/restart case; run it in isolation from
other log consumers. The normal GUI/export path does not stop the service.

## Build

On Windows:

    Build.bat

On Linux:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

0.85.44: Rebuilt with SDK0.64.57 and the shared R4STD Unicode17.0.0
extended grapheme editing boundaries. Byte offsets, scalar font advances
and grapheme clusters are distinct; no shaping or BiDi support is implied.
