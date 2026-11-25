---
name: review-security
description: Security review lens - injection, authz, secrets, unsafe defaults, data leakage.
---

# Security review

Review the change for security vulnerabilities:

- Authentication and authorization bugs, privilege-boundary mistakes.
- Injection: shell, SQL, path traversal, template, prompt injection.
- Secrets or credentials exposed in code, logs, or output.
- Unsafe deserialization or dependency behavior.
- Insecure defaults and data leakage.

Report only exploitable or clearly risky defects with concrete evidence and an exact code pointer.
No hardening wishlists, no speculation.
