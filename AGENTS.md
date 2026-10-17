# Development principles

Keep this codebase as small as possible. A very simple, ascetic UI is fine.

- Prioritize reuse: use Phoenix and LiveView conventions, existing components,
  and proven libraries when they reduce the amount of code we maintain.
- Prefer direct implementations. Avoid speculative abstractions, generic
  infrastructure, and dependencies that add more complexity than they remove.
- When reducing a feature's scope would considerably simplify the code, prefer
  the simpler approach. Explain the user-visible tradeoff to the user; do not
  silently drop agreed behavior.
- Keep HTML and CSS classes to a minimum. Use semantic elements, native controls,
  shallow markup, and a small amount of styling. Avoid decorative wrappers and
  elaborate visual polish.
- Keep the UI readable, accessible, and usable on phones and with a keyboard.
  Simplicity must preserve essential interaction and accessibility behavior.
- For the first version, follow conventional LiveView patterns rather than
  introducing a separate client-side application or offline synchronization.

# Testing

- Never write unit tests after writing the implementation.
- Highly prefer end-to-end tests as the sole testing mechanism. Exercise complex
  features through real user flows rather than restating implementation details.
- End-to-end runs must produce a verifiable, repeatable artifact, such as a
  browser trace, screenshots, or a report with reproduction steps.
- If a system must be tested in isolation, first write down how it could fail,
  then write the code.
- Delete low-signal unit tests that would not catch a real bug missed by the
  end-to-end suite. Delegate independent cleanup areas to parallel subagents.

# Deployment

- To deploy: check, commit, push, and verify Fly's native auto-deploy.
- No local deployments or GitHub Actions deployment workflows.
