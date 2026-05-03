---
name: explain-code
description: Explains code with visual diagrams and analogies. Use when explaining how code works, teaching about a codebase, walking through unfamiliar code, or when the user asks "how does this work?", "what is this doing?", or "explain this snippet."
---

# Explain Code

Teach how code works by leading with intuition, then grounding it in the source.

## When to use

- User asks "how does this work?", "what does X do?", "walk me through this"
- User is onboarding to a codebase or library
- User pastes a snippet and wants to understand it
- User asks for a mental model of a system, file, or function

## How to explain (in this order)

1. **Analogy first.** One sentence comparing the code to something everyday. *"This is a coat-check counter — you hand off a token, get a ticket, and pick up the same item later."* Pick analogies from the user's apparent domain when possible (kitchens for chefs, plumbing for backend devs, post offices for distributed systems).

2. **ASCII diagram.** Show the shape — flow, structure, or relationships. Examples:

   ```
   Request ──► Middleware ──► Handler ──► DB
                  │              │
                  └─ auth check  └─ writes audit log
   ```

   ```
   [Producer] ──┐
   [Producer] ──┼──► [Queue] ──► [Worker pool] ──► [Sink]
   [Producer] ──┘
   ```

   Keep diagrams small (≤ 12 lines). Label only what matters for the question.

3. **Walk the code step-by-step.** Reference real lines (`file.py:42`). For each step, say what it does in plain English *and why* it's there. Don't restate variable names — explain intent.

4. **Highlight one common misconception.** End with: *"A thing people miss here is..."* Surface a subtle invariant, an easy-to-miss edge case, a non-obvious order-of-operations, or a real trap the code avoids. One only — not a list.

## What to skip

- Don't restate the obvious (`x = 5` is "we set x to 5"). If a line is self-evident from its name, skip it.
- Don't dump every helper. Explain the spine; mention helpers only when they carry load-bearing logic.
- Don't write paragraphs of prose between code references. Short sentences, tight flow.

## Length target

For a single function: ~150–250 words including the diagram.
For a file or module: ~300–500 words.
For a full system: lead with one diagram + 3–5 short sections.

If you can't fit it in those bounds, you're explaining too much — pick the load-bearing parts.
