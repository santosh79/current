# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately, not in public issues or pull
requests.

Use GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/santosh79/current/security/advisories/new)**

Include what you can:

- what the issue is and what an attacker could do with it
- steps or a minimal proof of concept to reproduce it
- the Current version or commit, and your OS and Erlang/OTP version

I'll acknowledge reports within a few days, keep you updated as I
investigate, and credit you in the fix unless you'd rather not be named.
Current is maintained by one person, so please allow reasonable time for a
fix before disclosing publicly.

## Supported versions

Current is early software. Only the latest release and `main` receive
security fixes.

## Scope

Current's security model is described in the
[threat model](docs/threat_model.md). Please read it before reporting.

**In scope.** Ways to break a guarantee Current makes, for example:

- applying a proposal without a recorded approval and a separate `apply`
- reading or writing outside the project directory
- showing the model files the read policy excludes (`.env*`, dependencies,
  VCS directories, build output), including via symlinks
- running a command that isn't on the allowlist
- getting the runtime to accept a log whose hash chain has been altered
- bypassing the `Host` / `Origin` checks on the HTTP API or MCP endpoint
- intents outside the closed intent set being accepted or interpreted

**Known limitations (not vulnerabilities on their own).** These are
documented and on the roadmap:

- Current is **not a sandbox**: allowlisted commands run with the runtime's
  privileges, environment, filesystem and network access, and their
  arguments are unrestricted
- there is no command timeout, output cap or process-tree cleanup yet
- the HTTP API and MCP endpoint are **unauthenticated**; anyone who can
  reach them can approve and apply
- `reviewed_by` is whatever the client sends
- the log is tamper-evident to the runtime, but commits aren't signed, so
  someone who can write the data directory can rewrite and rehash history
- secrets in project files other than `.env*` are not recognised

If you find a way these limitations are worse than the threat model says,
that is in scope.
