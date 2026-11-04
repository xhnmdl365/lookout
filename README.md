# Lookout

A small floating panel for macOS that turns your Claude Code sessions into a task list, so you
can see at a glance what you're working on, what's waiting on you, and what's done, and jump
straight back into any session.

It reads sessions from the **Claude desktop app** (Code and Cowork) and from **`claude` in a terminal**.
Chat conversations aren't kept on your Mac, so they aren't tracked.

## What it shows

Tasks are grouped by what they need from you:

| Section | What's in it |
|---|---|
| **To-do** | Things you added yourself with **+**; they stay until you mark them done |
| **Active** | Worked on in the last 7 days (change it in Settings), or pinned. Tasks waiting on you, with an orange dot, lead it: blocked on you, or the last turn asked you something you haven't answered |
| **Idle lately** | Still open, but untouched for a while: finished or parked? |
| **Parked** | Set aside by you for later: long-running work, or something put off for now; it never drifts into Idle, and Triage skips it |
| **Scheduled** | The latest run of each scheduled task |
| **Done today** | Marked done today, by you or automatically |

The strip at the top counts each section, with an orange badge on Active for the tasks waiting
on you; click a number to jump there. A session started from another one is shown nested under
it, and a child waiting on you brings its whole family up with the tasks waiting on you.

While Claude is working on a task, its dot pulses and the row reads **Working** where the time
would be; a turn that has shown no activity for 15 minutes stops counting, in case the app quit
mid-turn. Each row shows the session's status, the next step it needs from you, where it runs (Claude app,
Cowork or Terminal, by icon), the project, branch and ticket status, when it last moved and how long it has run.
The ticket opens in Jira; a code review shows the teammate's PR it's about, which opens on GitHub.
Hover a row to pin it to the top of its section, park it, or mark it done. Click it to open the session: desktop
sessions open in the Claude app, Cowork tasks in its Cowork view; terminal sessions switch to their Terminal tab. One that isn't
running resumes in a Terminal tab already open in its folder and sitting at the prompt, or in a
new tab if there's none.

### Search

The magnifier at the top (or ⌘F) searches every task the panel knows, closed ones too: titles,
status and next step, folder, branch, ticket and PRs, and your to-dos' notes. Open tasks that
match stay under their sections; closed ones follow, grouped by the day they closed, newest
first. Click one to open it. Esc closes the search and brings the list back as you left it.
It runs on what the panel already holds, so it answers as you type; it doesn't search inside
transcripts.

### Your own to-dos

Not everything you track is a Claude session. **+** at the top adds a to-do: a title and an
optional note. To-dos carry a **To-do** badge instead of App or Terminal, and nothing tracks
them: no PRs, tickets or Triage. Click one to edit it; right-click to delete it.

They're done when you say so. One left over from an earlier day shows **Done yesterday**, and
right-click → **Mark done on** offers the past week, for any task: a task marked that way
counts in that day's record and summary, not today's.

### Done, automatically

A task is marked done without you when there's hard evidence:

- you archive or delete the session;
- its PRs are merged or closed, and you haven't worked in it since (checked with `gh`);
- **team code reviews** (reviewing someone else's PR) close when that PR is merged or closed;
- **your own tickets** close when Jira puts the ticket in its Done category (needs the Atlassian
  CLI; without it, PRs decide).

Anything marked automatically can be undone, and won't be marked again.

### How it tells what a task is

None of this depends on how you name sessions; it looks at what each session did.

- **Its ticket** comes from the session's title, else the branch it last checked out or pushed,
  else the branch or title of a PR you opened that it mentions. Keys found in branch names count
  only once Jira knows them, so `release-2024` isn't mistaken for a ticket. When several
  sessions share a folder, its current branch belongs to none of them in particular, so only a
  branch a session switched to or pushed is its own.
- **A team code review** is a session the Claude app links to a PR it read that isn't yours;
  or one that ran `gh pr checkout` or `gh pr review` on a teammate's PR; or diffed, viewed or
  mentions a teammate's PR that GitHub lists you as a reviewer on; or talks of a review next to a
  teammate's PR it mentions or looked at. A session that pushed a branch or opened a PR is your
  own work, and so is one titled with a ticket key that doesn't mention a review.

When it gets one wrong, right-click the task: set whether it's a code review or your own work,
and set or clear its ticket. Your choice wins over anything detected.

### Triage

Triage is off until you turn it on in **Settings → AI triage** (the gear at the top), since it uses your Claude plan;
until then its button, verdicts and suggestions stay hidden.

**Triage** asks Claude for a one-line verdict on each task in Active. The panel
first checks PR and ticket states itself, then hands Claude the task list with those states in
the prompt. Claude runs with no tools, so it sees only that list, never your transcripts or other
files, and answers in one go. With hard evidence
it marks a task done; otherwise it suggests wrapping up, and you decide. Only tasks that changed
since their last verdict are sent; unchanged ones are rechecked once a day.

Triage and day summaries run `claude -p` on your own Claude plan: they count toward your plan's
usage, they aren't billed per call. The footer shows today's runs and tokens.

### History

Each day's list is kept as a snapshot. Page back with ‹ › to see what was finished and what moved
that day, with a summary Claude writes the next morning from what each session did that day (the
recap Claude wrote after each turn, or what you asked in a terminal session), with each task's ticket
status and the state of the PRs it mentioned that day: one line per task you worked on, with
✅ finished, ⛔ blocked or waiting, ⏳ in progress, and one line for the PRs you reviewed. It opens
with a short overall paragraph: where the time went, from how long each task was worked on that
day, what was finished, and what has been open for days. Quick questions and chores on your own
tools are left out. Past days only change when you edit them.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools with Swift 5.9 or later (Xcode 15 or later), to build
  (`xcode-select --install`; `swiftc --version` shows which you have)
- The Claude desktop app and/or Claude Code in a terminal

Optional, each one adds to what the panel can do:

| Tool | What it adds | Set up |
|---|---|---|
| [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI | Triage and day summaries | `claude auth login` |
| [GitHub CLI](https://cli.github.com) | PR status, so merged PRs close tasks | `brew install gh`, then `gh auth login` |
| [Atlassian CLI](https://developer.atlassian.com/cloud/acli/) | Jira ticket status for your own work | see below |

Installing the Atlassian CLI with Homebrew (Homebrew asks you to trust the tap's formula first):

```bash
brew tap atlassian/homebrew-acli
brew trust --formula atlassian/acli/acli
brew install acli
acli jira auth login --web
```

**Settings → Integrations** shows which of these are found and signed in.

## Build and run

```bash
git clone https://github.com/xhnmdl365/lookout.git
cd lookout
./build.sh
open Lookout.app
```

To update later: `git pull`, then `./build.sh` again and reopen the app. You can move
`Lookout.app` to `/Applications` if you like; it keeps its data in its own folder either way.

The panel stays on top of other windows. Closing or minimizing it only hides it; click Lookout
in the Dock (or its menu bar icon) to bring it back. To rebuild the app icon after changing it:
`swift scripts/make-icon.swift`.

## Optional: session naming

In Settings you can add a short rule to your own `~/.claude/CLAUDE.md` that has Claude name a
session reviewing a teammate's PR "Team code review: …". The panel then recognises review
sessions at once, even before Claude runs any `gh` command. Without the rule they're still found
from what the session did. The rule is added between markers, and Settings can remove it again.

## Your own settings

Personal settings go in `config.json` in the data folder
(`~/Library/Application Support/ClaudeTasks/`), never in this repo. Every key is optional:

```json
{
  "claudePath": "/path/to/claude",
  "ghPath": "/path/to/gh",
  "acliPath": "/path/to/acli",
  "githubOrg": "your-org",
  "jiraSite": "yourteam.atlassian.net",
  "triageModel": "sonnet",
  "blockedDays": 14,
  "scheduledDays": 7,
  "prGraceHours": 6,
  "reverifyHours": 24,
  "refreshMinutes": 10
}
```

- Tool paths are only needed when a tool isn't in a usual place (Homebrew, `~/.local/bin`, …).
- `githubOrg` is used for mentions like `api#123` in folders that aren't a GitHub repo; by
  default it's the org most of your folders point to.
- `jiraSite` is where ticket links go; by default it's the site the Atlassian CLI is signed in to.

Text sizes are set in **Settings → Text size**, and the theme in **Settings → Appearance**: System
follows macOS, or pick Light or Dark.

## Privacy

- The panel reads local files only: the Claude desktop app's session records
  (`~/Library/Application Support/Claude/claude-code-sessions`, and `local-agent-mode-sessions`
  for Cowork) and Claude Code transcripts (`~/.claude/projects`). It doesn't modify any of them.
- It writes only to its own data folder, plus `~/.claude/CLAUDE.md` if you add the naming rule.
- It makes no network calls of its own; `claude`, `gh` and `acli` do, as you, when it runs them.

## Caveats

- The Claude desktop app's session records aren't a documented format and may change with app
  updates; fields the panel can't read are left blank.
- Cowork records carry no status summary, so a Cowork task shows its last prompt, and whether
  Claude is working on it comes from its transcript.
- Switching to a running terminal session works with Terminal.app; macOS asks once for
  permission to control it.

## License

[MIT](LICENSE)
