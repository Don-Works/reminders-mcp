# Security policy

## Supported versions

Security fixes are made against the latest released version of `reminders-mcp`.
Upgrade before reporting an issue that may already be resolved.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue. Use the
[private vulnerability reporting form](https://github.com/Don-Works/reminders-mcp/security/advisories/new)
and include:

- the affected version and macOS release;
- the security boundary or data at risk;
- minimal reproduction steps; and
- any suggested mitigation.

Do not include the contents of your own reminders, calendar data, or any other
personal content in a report. Ask for a secure transfer channel first if
reproduction requires a sensitive artifact.

## Deployment boundary

This server reads and writes the Reminders store of the user who runs it, with
no authentication of its own — it inherits whatever access macOS granted the
process. Treat the stdio channel as trusted: anything that can write to it can
read and modify every reminder the user can. Do not expose it over a network
transport without an authenticated, encrypted layer in front, and do not run it
under an identity with broader Reminders access than the caller should have.

Ordinary bugs and feature requests belong in the public issue tracker.
