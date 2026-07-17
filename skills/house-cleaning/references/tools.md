# Dead-code detectors by ecosystem

Stage-1 evidence sources. A detector hit is ONE signal; dynamic languages need a second
independent signal (no inbound imports, zero coverage, artifact pattern, git archaeology).

| Ecosystem | Tool | Invocation | Notes |
|---|---|---|---|
| JS/TS | knip | `npx knip` | Unused files, exports, deps. Configure entry points or expect false positives. |
| JS/TS | tsc | `npx tsc --noEmit` | Unused-local diagnostics with `noUnusedLocals`. |
| Python | vulture | `vulture . --min-confidence 80` | AST-based; `getattr`/reflection invisible — always needs the second signal. |
| Go | deadcode | `go run golang.org/x/tools/cmd/deadcode@latest ./...` | Sound: a report means unreachable even dynamically. |
| Rust | cargo-machete | `cargo machete` | Fast, text-level; proc-macro usage invisible. |
| Any | git | `git log -1 --format=%ci -- <path>` | Recency is corroborating only — stable ≠ dead. |
| Any | grep | `grep -rn "<symbol>" --include=<glob>` | Zero references outside the definition = one signal. |

False-positive shape shared by all static detectors: dynamic imports, reflection,
plugin registration, entry points, config-referenced modules. That is what the
deletion test (stage 2) is for — the detector only nominates.
