# Repository agent instructions

## Aspect compiler integration

The canonical fork-only compiler line is `casselc/jolt:integration/aspects`.
Branch aspect compiler, effect-analysis, source-annotation, preset, and
instrumentation work from that ref and return it through a pull request whose
base is that ref.

Read `docs/aspect-compiler-integration.md` before changing the aspect line. Do
not rebase or force-push `integration/aspects`; published consumers pin exact
commits. Track released upstream Jolt revisions on the canonical line and use a
separate canary for moving upstream `main`.

Before publishing a branch, run:

```bash
bash test/aspect-integration-provenance-smoke.sh
bash test/aspect-integration-provenance-smoke.sh --check-upstream
```

The first command is offline and deterministic. The second verifies the
recorded upstream release commit and tree against the live remote. Updating
`config/aspect-integration.lock` is a provenance change and must include the
corresponding evidence and migration notes.

All local source builds and compiler gates use an explicitly selected Chez
Scheme 10.4.1 toolchain. Follow `CONTRIBUTING.md` and any enclosing workspace
instructions; do not let another installed Chez version be selected implicitly.
