# Claude Tasks

A small floating panel for macOS that turns your Claude Code sessions into a task list, so you
can see at a glance what you're working on, what's waiting on you, and what's done, and jump
straight back into any session.

It reads sessions from the **Claude desktop app** (Code tab) and from **`claude` in a terminal**.

## What it shows

Tasks are grouped by what they need from you:

| Section | What's in it |
|---|---|
| **Needs you** | The session is blocked on you, or its last turn asked you something you haven't answered |
| **In progress** | Worked on in the last 36 hours, or pinned |
| **Idle lately** | Still open, but untouched for a while: finished or parked? |
| **On hold** | Put aside by you; Triage skips these |
| **Scheduled** | The latest run of each scheduled task |
| **Done today** | Marked done today, by you or automatically |

The strip at the top counts each section; click a number to jump there. A session started from
another one is shown nested under it, and a child waiting on you brings its whole family into
**Needs you**.

Each row shows the session's status, the next step it needs from you, where it runs (Claude app
or Terminal), the project, branch and ticket status, when it last moved and how long it has run.
Hover a row to pin it, put it on hold, or mark it done. Click it to open the session: desktop
sessions open in the Claude app; terminal sessions switch to their Terminal tab, or resume in a
new one if they aren't running.

### Done, automatically

A task is marked done without you when there's hard evidence:

- you archive or delete the session;
- its PRs are merged or closed, and you haven't worked in it since (checked with `gh`);
- **team code reviews** (reviewing someone else's PR) close when that PR is merged or closed;
- **your own tickets** close when Jira puts the ticket in its Done category (needs the Atlassian
  CLI; without it, PRs decide).

Anything marked automatically can be undone, and won't be marked again.

### Triage

**Triage** asks Claude for a one-line verdict on each task in Needs you and In progress. Claude
looks at status only (the task list and `gh pr view`), never your transcripts. With hard evidence
it marks a task done; otherwise it suggests wrapping up, and you decide. Only tasks that changed
since their last verdict are sent; unchanged ones are rechecked once a day.

Triage and day summaries run `claude -p` on your own Claude plan: they count toward your plan's
usage, they aren't billed per call. The footer shows today's runs and tokens.

### History

Each day's list is kept as a snapshot. Page back with ‹ › to see what was finished and what moved
that day, with a short summary Claude writes the next morning. Past days only change when you
edit them.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools, to build (`xcode-select --install`)
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
./build.sh
open ClaudeTasks.app
```

The panel stays on top of other windows. Closing it only hides it; open the app again (or use
its menu bar icon) to bring it back.

## Optional: session naming

In Settings you can add a short rule to your own `~/.claude/CLAUDE.md` that has Claude name a
session reviewing a teammate's PR "Team code review: …". The panel then recognises review
sessions at once. Without the rule they're still found, by the PR's author. The rule is added
between markers, and Settings can remove it again.

## Your own settings

Personal settings go in `config.json` in the data folder
(`~/Library/Application Support/ClaudeTasks/`), never in this repo. Every key is optional:

```json
{
  "claudePath": "/path/to/claude",
  "ghPath": "/path/to/gh",
  "acliPath": "/path/to/acli",
  "githubOrg": "your-org",
  "triageModel": "sonnet",
  "activeHours": 36,
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

Text sizes are set in **Settings → Text size**.

## Privacy

- The panel reads local files only: the Claude desktop app's session records
  (`~/Library/Application Support/Claude/claude-code-sessions`) and Claude Code transcripts
  (`~/.claude/projects`). It doesn't modify either.
- It writes only to its own data folder, plus `~/.claude/CLAUDE.md` if you add the naming rule.
- It makes no network calls of its own; `claude`, `gh` and `acli` do, as you, when it runs them.

## Caveats

- The Claude desktop app's session records aren't a documented format and may change with app
  updates; fields the panel can't read are left blank.
- Switching to a running terminal session works with Terminal.app; macOS asks once for
  permission to control it.
