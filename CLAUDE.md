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

The same applies to anything you write into a file. Comments, docs,
checklists and commit messages are all held to it: a statement earns its
place by changing what a reader would do.

# Communication style

- Keep replies clear and simple. No flourish, no unnecessary preamble or filler. State things directly and get to the point.
- Don't suggest next steps that are off-topic from what was asked.
- For explanations longer than 500 words, lead with a short high-level summary, then the details.
- Structure each explanatory section as: a 1-2 sentence summary of the fact, then a paragraph on what it implies in practice, then the supporting detail and evidence if relevant. Don't label the parts, let the order carry it.
- Avoid tables. Use lists instead.
- Never use em-dashes. Use colons instead if needed.
- Remove words or phrases that don't change the meaning of the sentence.
- Avoid idiomatic filler phrases that only add tone, not content.
- Every factual claim or answer needs justification: cite the code, data, or source it's based on. If a claim can't be backed by something verified, say so explicitly and mark it as uncertain rather than stating it flatly.
- Write docs in first person plural ("we build only the proxy"), not second person.
- Lead with the fact. No framing headers ("Four things that surprise people", "The thing to understand is") and no labels telling the reader how to react (surprising, tricky, worth noting).
- Never use a metaphor that the following sentence then explains. State the thing directly.

# Reply structure

- Be brief. Default to short. Cut any sentence that does not carry new information.
- Structure every substantive reply as: a short summary, then only the detail that summary needs, then a list of follow-up questions I can pick from.
- Put the follow-up questions last, as a short numbered list, so I can answer by number. Only questions I might actually want answered next, not a survey.
- Do not restate what was just said in a previous reply.

# Layers

Read the folder's `CLAUDE.md` before working there.

- `scripts/`: numbered shell steps by category (init, dev, test, build, pf, cleanup, util). Read `scripts/CLAUDE.md`.
- `scripts/app/`: inspector and repro scripts. Covered by `scripts/CLAUDE.md`.
- `scripts/examples/`: composed setups (grafana, custom_image, bel, load_test). Read `scripts/examples/CLAUDE.md`.
- `l4_proto_inspector/`: the L4 protocol inspector app. Read `l4_proto_inspector/CLAUDE.md`.
- `checklist/`: checklists for sessions. Read `checklist/CLAUDE.md`.
- Prefer composing an example from existing scripts over writing new ones.

# Workflow

- Use well scoped and small sub-agents so the main loop stays lean (e.g. explore code, fetch info, running tests).

## Checklist-driven sessions

Every session works from a checklist file in `checklist/`, named `checklist_<concern>.md`, for example `checklist_load_test_linkerd.md`. Finished checklists move to `checklist/complete/`.

### Starting a session

- List the existing `checklist_*.md` files and ask which one this session is working from. Never infer it from the first request.
- If the concern is new, or no checklist exists, do not start work. Ask clarifying questions first, write the checklist from the answers, and confirm it before touching anything.
- If picking up an existing checklist, confirm which items are in scope for this session.

### Doing the work

Our job in the main loop is to manage the checklist and verify that items actually get completed. It is not to do the tasks.

- Dispatch each checklist item to a sub-agent. Give it a scoped prompt that states what counts as done and what evidence to return.
- Send independent items in a single message so they run concurrently.
- Sub-agents return conclusions, not file dumps or raw command output.
- Do not take a sub-agent's report at face value. Spot-check any claim that changes what we do next.
- Work directly only when dispatching costs more than the task itself, such as a single file read or a one-line command.

### Updating the checklist

- Update the file as work progresses, not at the end.
- Mark an item `[x]` only when verified, not when merely attempted. Record what verified it.
- Add newly discovered work as items rather than doing it silently.
- When an item turns out to be wrong or blocked, keep it and write the reason underneath. Do not delete it.
- Completed items stay in the file. The checklist is the running record for that concern.

### Format

- `## Tasks` at the top: a flat list of `- [ ]` tasks, one line each, numbered `1.`, `2.`, `n.` with no letter prefix. **This is the only checklist in the file.**
- Then one `## n. <task name>` section per task, in the same order and using the same number.
- **A task section carries no checkboxes of its own.** It is prose and commands: what the task is for, how to do it, and what counts as done. Granularity comes from having more tasks, not from nesting boxes inside one.
- **If a task needs sub-items to stay clear, it is too large. Split it into several tasks.**
- Write each section so a sub-agent with no context could execute it: the exact commands, the files involved, the preconditions, the expected output, and how to verify the result. State what must not be touched.
- Refer to a task elsewhere in the file as "task n".
- Record evidence, commands and measured numbers inside the section, under a `Result` heading once the task is done.
- Keep a `## Context` section for the environment facts the tasks depend on.
- Keep an `## Open questions` section for anything unresolved. Say which task each question blocks, and note it in that task's section too.
