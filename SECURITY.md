# Security policy
This policy applies to `StrawberryMaster/wayback-machine-downloader` and the
`wayback_machine_downloader_straw` RubyGem.

## Supported versions
Security updates are provided for the latest release line only (so always upgrade to
the latest patch release).

| Version | Supported |
| --- | --- |
| 2.5.x | Yes |
| < 2.5 | No |

## Reporting a vulnerability
Please report suspected security vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/StrawberryMaster/wayback-machine-downloader/security/advisories/new).

**Do not** disclose the vulnerability in a public issue, discussion, or pull request. In the event you have already disclosed a vulnerability, but have not received a response, please file a normal issue noting that you have already disclosed the vulnerability. We will respond as soon as possible.

To help us triage your report quickly, please include:
- The affected version and platform (OS / Ruby version)
- A clear description of the impact
- Verified reproduction steps or a proof of concept (please do not submit unverified automated scanner or AI-generated output)
- Any suggested mitigation, if known

### Scope
- **In scope:** vulnerabilities in the downloader itself when processing untrusted CDX/archive data or URLs (e.g., path traversal, arbitrary file writes outside the backup directory, command injection, unsafe symlink handling).
- **Out of scope:**  malicious content (such as XSS or scripts) inside archived web pages downloaded from the Wayback Machine, denial-of-service from downloading very large sites, or issues specific to other forks.

## Disclosure and response
This project is maintained on a best-effort basis. We aim to acknowledge reports
within a few days and work with you on a fix before public disclosure. Please give
us reasonable time to investigate and release a patch before publishing details.

There is no bug bounty program; reporters of valid vulnerabilities will be
credited in the published GitHub Security Advisory if desired.