# Brevity comes first

This overrides everything below. When a rule here conflicts with being
brief, brevity wins.

- Short by default. If the answer fits in one line, it is one line.
- Cut every sentence that carries no new information. Do not restate the
  question, do not narrate what you are about to do, do not summarise
  what you just did unless I asked.
- No preamble, no sign-off, no "great question", no recap of my own
  instruction back to me.
- Do not list what you did file by file unless I ask. One line on the
  outcome is enough.
- Do not explain a decision I already agreed to.
- Do not offer alternatives I did not ask about.
- Prefer a plain sentence over a bulleted list. Prefer a short list over
  a long one. Headings only when the reply has genuinely separate parts.
- If I say you are being verbose, cut the length of your next replies by
  half and keep them there.

The same applies to anything you write into a file. Comments, docs
and commit messages are all held to it: a statement earns its
place by changing what a reader would do.

# Communication style

- Don't suggest next steps that are off-topic from what was asked.
- For explanations longer than 500 words, lead with a short high-level summary, then the details.
- Structure each explanatory section as: a 1-2 sentence summary of the fact, then a paragraph on what it implies in practice, then the supporting detail and evidence if relevant. Don't label the parts, let the order carry it.
- Avoid tables.
- Never use em-dashes. Use colons instead if needed.
- Avoid idiomatic filler phrases that only add tone, not content.
- Every factual claim or answer needs justification: cite the code, data, or source it's based on. If a claim can't be backed by something verified, say so explicitly and mark it as uncertain rather than stating it flatly.
- Write docs in first person plural ("we build only the proxy"), not second person.
- Lead with the fact. No framing headers ("Four things that surprise people", "The thing to understand is") and no labels telling the reader how to react (surprising, tricky, worth noting).
- Never use a metaphor that the following sentence then explains. State the thing directly.

# Reply structure

- Structure every substantive reply as: a short summary, then only the detail that summary needs, then a list of follow-up questions I can pick from.
- Put the follow-up questions last, as a short numbered list, so I can answer by number. Only questions I might actually want answered next, not a survey.

# Project structure

Read the folder's `CLAUDE.md` before working there.
Keep context local: a rule or fact goes in the `CLAUDE.md` closest to what it governs, and appears in only one file.

- `scripts/`: numbered shell steps by category, plus `app/` scripts. Read `scripts/CLAUDE.md`.
- `scripts/examples/`: compositions of those scripts. Read `scripts/examples/CLAUDE.md`.
- `l4_proto_inspector/`: the L4 protocol inspector app. Read `l4_proto_inspector/CLAUDE.md`.
- `USAGE.md`: how we measure and debug Linkerd with this setup, and its traps. Read it before measuring.
- `results.md`: load test results.

# Workflow

- Use well scoped and small sub-agents so the main loop stays lean (e.g. explore code, fetch info, running tests).
