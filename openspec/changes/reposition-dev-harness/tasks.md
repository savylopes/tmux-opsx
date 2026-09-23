## 1. OpenSpec context

- [x] 1.1 Check the project `config.yaml` format expected by the installed OpenSpec version (`schema`, `context`, `rules`)
- [x] 1.2 Create `openspec/config.yaml` with the context described in design.md Decision 2 (under ~40 lines)
- [x] 1.3 Confirm `openspec instructions proposal --change reposition-dev-harness` includes the context, and `openspec validate --all --strict` passes

## 2. README

- [x] 2.1 Rewrite the intro and add the component overview tree (shipped components only)
- [x] 2.2 Reorder sections: Install, Workflow, Gates, Context, Supported CLIs, Uninstall — moving existing content, not dropping it
- [x] 2.3 Diff old vs new README and confirm every documented command, flag and option is still present

## 3. Verification

- [x] 3.1 Run `install.sh` in a scratch `HOME` before and after the change and confirm identical installed files
