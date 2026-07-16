# Test CLAUDE.md

pipeline:
  toolchain:
    imports: [yaml, jsonschema, pytest]
    infra: [bash, jq, shellcheck, sonar-scanner]

  smoke_test:
    - echo "smoke test"

  contracts: []

  grinder:
    languages: [bash, python]
    findings:
      shellcheck:
        paths: [claude/tools/]
      ruff:
        paths: [src/]
      fix_rules_allowlist: []
      never_touch_files: []
