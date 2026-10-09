import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Ticket, TicketState, TaskNode, TaskStatus, Pin } from '../types'

const PANE = 'session-ticker'
const PIN_PREFIX = 'pin-' // pane ids: letters/digits/_/- only, no ':'

const tickets = atom({ plugin: 'session-ticker', key: 'tickets' } as const, [] as Ticket[])
const tasks = atom({ plugin: 'session-ticker', key: 'tasks' } as const, [] as TaskNode[])
const pins = atom({ plugin: 'session-ticker', key: 'pins' } as const, [] as Pin[])

// Config (filled from userConfig in register; defaults match the manifest).
let CFG = { summaryModel: 'haiku', summaryEverySeconds: 45, ttlMinutes: 6, maxCards: 0, activeSeconds: 20 }

// This session's own ticket, kept in module vars (re-seeded on every load).
let myKey = '' // stable filename key (<host>__<sanitized cwd>) — no event needed
let myId = '' // real session id when an event gives us one, else myKey
let myCwd = ''
let myHost = 'local' // SHELLINATOR_HOST — namespaces state files so a NAS-shared
let myHostResolved = false // ~/.claude doesn't collide across hosts; board filters by it
let mySummary = 'started session'
let mySource = 'startup'
let myState: TicketState = 'working'
let lastAction = '' // last tool action this session performed
let myLastActivity = 0 // real activity only (prompt/tool), NOT the 30s heartbeat
let lastSummaryAt = 0 // throttle the model summary
let booted = false
let lastErr = ''

// Shared, same-host directory every session writes its ticket into.
// Default lives under the user's Claude dir (shared across that user's sessions
// on the host); override with SESSION_TICKER_DIR to point at a shared mount.
async function ticketDir($: any): Promise<string> {
  const override = await $.env.get('SESSION_TICKER_DIR')
  if (override) return override
  const home = await $.env.get('HOME')
  return home ? `${home}/.claude/session-ticker/tickets` : '.session-ticker/tickets'
}

// Per-SESSION task stack, not per-project: written directly by the model
// (Write/Edit tools, per the session-task-stack skill), keyed by sanitized
// cwd — the same key `myKey` already uses for tickets, computed by this
// plugin, never by the model. Deliberately NOT keyed by real session id:
// e.session_id is never populated by any event this plugin receives (see
// `ensure()` below), so a UUID-keyed scheme forces the model to self-report
// its own id every write, which it sometimes gets wrong by copying a stale
// id off an existing file — that caused real cross-session data corruption.
// cwd-keying can't have that failure mode: the model never chooses the key.
// This plugin only ever reads its own session's file here.
async function tasksDir($: any): Promise<string> {
  const override = await $.env.get('SESSION_TASKS_DIR')
  if (override) return override
  const home = await $.env.get('HOME')
  return home ? `${home}/.claude/session-ticker/tasks` : '.session-ticker/tasks'
}

// Pinned chat messages, same cwd-keyed-file convention as tasks (see
// tasksDir above) — one file per worklog directory, content written by
// both the model (Write/Edit, to add/update a pin) and this plugin itself
// (to record which line got clicked, and to drop a pin on close).
async function pinsDir($: any): Promise<string> {
  const override = await $.env.get('SESSION_PINS_DIR')
  if (override) return override
  const home = await $.env.get('HOME')
  return home ? `${home}/.claude/session-ticker/pins` : '.session-ticker/pins'
}

async function loadPins($: any): Promise<Pin[]> {
  if (!myKey) return []
  try {
    const dir = await pinsDir($)
    const txt = await $.fs.read(`${dir}/${myKey}.json`)
    const parsed = JSON.parse(txt) as { pins?: Pin[] }
    return Array.isArray(parsed.pins) ? parsed.pins : []
  } catch {
    return []
  }
}

async function savePins($: any, list: Pin[]): Promise<void> {
  if (!myKey) return
  const dir = await pinsDir($)
  await $.fs.write(`${dir}/${myKey}.json`, JSON.stringify({ pins: list }))
}

function sanitize(s: string): string {
  return s.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'unknown'
}

function base(p: unknown): string {
  const s = String(p ?? '')
  return s.split('/').filter(Boolean).pop() || s
}

function clip(s: unknown, n: number): string {
  const t = String(s ?? '').replace(/\s+/g, ' ').trim()
  return t.length > n ? t.slice(0, n - 1) + '…' : t
}

// Turn a tool call into a short, human "what's happening" line.
function describeAction(e: any): string {
  switch (e.tool) {
    case 'Bash':
      return `running: ${clip(e.command, 56)}`
    case 'Edit':
    case 'MultiEdit':
    case 'Write':
      return `editing ${base(e.file_path)}`
    case 'NotebookEdit':
      return `editing ${base(e.notebook_path ?? e.file_path)}`
    case 'Read':
      return `reading ${base(e.file_path)}`
    case 'Grep':
      return `grep "${clip(e.pattern, 36)}"`
    case 'Glob':
      return `glob ${clip(e.pattern, 40)}`
    case 'WebFetch':
      return `fetching ${clip(e.url, 44)}`
    case 'WebSearch':
      return `web search: ${clip(e.query, 40)}`
    case 'Task':
    case 'Agent':
      return `subagent: ${clip(e.description ?? e.subagent_type, 40)}`
    case 'Skill':
      return `skill: ${clip(e.skill ?? e.command, 32)}`
    default:
      return typeof e.tool === 'string' ? clip(e.tool, 40) : 'working'
  }
}

function short(s: string): string {
  const w = String(s ?? '').replace(/\s+/g, ' ').trim().split(' ').filter(Boolean)
  let t = w.slice(0, 12).join(' ')
  if (t.length > 72) t = t.slice(0, 71) + '…'
  else if (w.length > 12) t = t + ' …'
  return t || '(empty)'
}

function age(now: number, then: number): string {
  const s = Math.max(0, Math.round((now - then) / 1000))
  if (s < 60) return `${s}s`
  const m = Math.round(s / 60)
  if (m < 60) return `${m}m`
  return `${Math.round(m / 60)}h`
}

// A stable accent colour per session, so each card reads as its own "shard".
const PALETTE = ['cyan', 'green', 'yellow', 'magenta', 'blue', 'red', 'white'] as const
function accentOf(key: string): string {
  let h = 0
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0
  return PALETTE[h % PALETTE.length]
}

function stateOf(t: Ticket): TicketState {
  if (t.state) return t.state
  const s = (t.summary || '').toLowerCase()
  if (s.startsWith('ended')) return 'ended'
  if (s.startsWith('idle')) return 'idle'
  return 'working'
}

function rank(s: TicketState): number {
  return s === 'needs-you' ? 0 : s === 'working' ? 1 : s === 'idle' ? 2 : 3
}

// How a state renders: glyph, colour, whether it overrides the accent border.
function view(s: TicketState): { glyph: string; color: string; border: string | null; tag: string } {
  if (s === 'needs-you') return { glyph: '◉', color: 'red', border: 'red', tag: ' ⚠ needs you' }
  if (s === 'ended') return { glyph: '✓', color: 'gray', border: 'gray', tag: '' }
  if (s === 'idle') return { glyph: '○', color: 'yellow', border: null, tag: '' }
  return { glyph: '●', color: 'green', border: null, tag: '' }
}

// A teammate-style status: ask the summary model to summarize this session's
// recent transcript in ≤10 words. Cheap (small model, short output), throttled,
// and skipped entirely when summaryModel is 'off'.
async function teammateStatus($: any): Promise<string | null> {
  if (CFG.summaryModel === 'off') return null
  try {
    const msgs = (await $.session.messages()) ?? []
    const recent = msgs
      .slice(-8)
      .map((m: any) => {
        let text = (m.text ?? '').toString()
        if (!text && Array.isArray(m.toolUses) && m.toolUses.length) {
          text = m.toolUses.map((t: any) => t.tool).filter(Boolean).join(', ')
        }
        return `${m.role}: ${text.replace(/\s+/g, ' ').slice(0, 300)}`
      })
      .filter((l: string) => l.trim().length > 0)
      .join('\n')
    if (!recent.trim()) return null
    const prompt =
      'Write a one-line status update to a teammate describing what THIS session just did or is working on. ' +
      '10 words or fewer. Concrete, no preamble, no quotes, no trailing period needed.\n' +
      'Examples: "Refactored the auth module; tests green." / "Investigating a failing CI run; flaky test suspected."\n\n' +
      `Recent activity:\n${recent}\n\nStatus:`
    const r = await $.model.complete({ model: CFG.summaryModel, prompt })
    if (r?.isAnswered && r.text) {
      return short(
        String(r.text)
          .replace(/^\s*status:\s*/i, '')
          .replace(/^["']|["']$/g, '')
          .trim(),
      )
    }
    return null
  } catch {
    return null
  }
}

async function writeMine($: any, ended?: boolean): Promise<void> {
  if (!myKey) return
  try {
    const dir = await ticketDir($)
    const host = myHost
    const label = myCwd.split('/').filter(Boolean).pop() ?? myKey
    const t: Ticket = {
      key: myKey,
      sessionId: myId || myKey,
      label,
      host,
      summary: mySummary,
      source: mySource,
      state: ended ? 'ended' : myState,
      updated: await $.clock.now(),
      lastActivity: myLastActivity,
      ...(ended ? { ended: true } : {}),
    }
    await $.fs.write(`${dir}/${myKey}.json`, JSON.stringify(t))
    lastErr = ''
  } catch (err) {
    lastErr = `write: ${String((err as any)?.message ?? err)}`
  }
}

async function refresh($: any): Promise<void> {
  const dir = await ticketDir($)
  const list: Ticket[] = []
  try {
    const entries = await $.fs.list(dir)
    for (const ent of entries) {
      if (ent.kind !== 'file' || !ent.name.endsWith('.json')) continue
      try {
        const txt = await $.fs.read(`${dir}/${ent.name}`)
        const t = JSON.parse(txt) as Ticket
        if (t && typeof t.updated === 'number') list.push(t)
      } catch {
        /* skip an unreadable or half-written ticket */
      }
    }
  } catch {
    /* dir not created yet */
  }
  const now = await $.clock.now()
  const ttl = Math.max(1, CFG.ttlMinutes) * 60_000
  let live = list.filter(t => !t.ended && stateOf(t) !== 'ended' && now - t.updated < ttl)
  // Same-host board: when we know our host, show only this host's sessions
  // (a NAS-shared ticket dir can hold other hosts' files). If host resolution
  // failed (myHost === 'local'), don't hide anything — show them all.
  if (myHost !== 'local') live = live.filter(t => (t.host || 'local') === myHost)
  live.sort((a, b) => b.updated - a.updated)
  await update($, tickets, () => live)
  const need = live.filter(t => stateOf(t) === 'needs-you').length
  $.ui.status(
    live.length ? `◈ ${live.length} live${need ? ` · ${need} need you` : ''}` : undefined,
  )

  // This session's own task stack — written by the model directly, never by
  // this plugin. Keyed by myKey (sanitized cwd), computed by this plugin the
  // same way the ticket file is — no pointer indirection, no session-id
  // self-report, so the model can never target the wrong file.
  if (myKey) {
    try {
      const tdir = await tasksDir($)
      const txt = await $.fs.read(`${tdir}/${myKey}.json`)
      const parsed = JSON.parse(txt) as { tasks?: TaskNode[] }
      await update($, tasks, () => (Array.isArray(parsed.tasks) ? parsed.tasks : []))
    } catch {
      await update($, tasks, () => [])
    }
  }

  // Pinned messages — same cwd-keyed file, read on the same cadence so a
  // model edit (adding/updating a pin's lines) shows up without a restart.
  const pinList = await loadPins($)
  await update($, pins, () => pinList)
}

// Lazily initialize from whatever event fired (session.start never fires on a
// mid-session enable); start the heartbeat + refresh timers once.
async function ensure($: any, e?: any): Promise<void> {
  if (e?.session_id) myId = e.session_id
  if (e?.cwd) myCwd = e.cwd
  if (!myCwd) {
    try {
      myCwd = await $.session.cwd()
    } catch {
      /* leave empty */
    }
  }
  if (!myHostResolved) {
    myHost = (await $.env.get('SHELLINATOR_HOST')) || 'local'
    myHostResolved = true
  }
  // Host-namespaced key: <host>__<sanitized cwd>. On a NAS-shared ~/.claude two
  // hosts sitting in the same cwd would otherwise write the same filename and
  // clobber each other's ticket/task/pin state — the host prefix keeps them
  // distinct. The session-task-stack / pin-preview skills build the SAME key.
  if (!myKey) myKey = `${sanitize(myHost)}__${sanitize(myCwd)}`
  if (!myId) myId = myKey
  if (!booted) {
    booted = true
    myLastActivity = await $.clock.now()
    await writeMine($)
    $.clock.every(30_000, () => void writeMine($)) // liveness only — does not touch myLastActivity
    $.clock.every(5_000, () => void refresh($))
  }
}

export const register: Register = (on, options) => {
  CFG = {
    summaryModel: String(options?.summaryModel ?? 'haiku'),
    summaryEverySeconds: Number(options?.summaryEverySeconds ?? 45),
    ttlMinutes: Number(options?.ttlMinutes ?? 6),
    maxCards: Number(options?.maxCards ?? 0),
    activeSeconds: Number(options?.activeSeconds ?? 20),
  }

  on('session.start', async ($, e, next) => {
    mySummary = e.source === 'resume' ? 'resumed session' : 'started session'
    mySource = e.source
    myState = 'working'
    await ensure($, e)
    await $.command.register({ name: 'ticker', description: 'Open the live session ticker' })
    await $.command.register({
      name: 'pin',
      description:
        'Pin exact text as its own tab next to the ticker. Mechanical only — does not resolve "pin that" itself; see the pin-preview skill for picking which message is meant.',
    })
    void $.ui.open({ id: PANE, title: 'Session ticker' })
    void refresh($)
    // Reopen every surviving pin as its own tab. Without this, a pin only
    // exists until the next session.start (startup, resume, clear, OR
    // compact) — the ticker pane re-opens itself here, but a pin pane never
    // did, so it silently vanished across a compaction boundary with no
    // error anywhere. No `focus` here: come back as background tabs, don't
    // steal focus from whatever the person was looking at.
    void (async () => {
      for (const p of await loadPins($)) {
        try {
          await $.ui.open({ id: PIN_PREFIX + p.id, title: p.title })
        } catch {
          /* best-effort */
        }
      }
    })()
    return next(e)
  })

  on('command.run', { command: 'ticker' }, async $ => {
    await ensure($)
    await $.ui.open({ id: PANE, title: 'Session ticker' })
    await refresh($)
    return { text: `Session ticker opened.${lastErr ? ' (err: ' + lastErr + ')' : ''}` }
  })

  // Park a chat message as its own tab next to the ticker. The pane id is
  // dynamic (one per pin) — $.ui.open with a new id is what gives the native
  // tab (click to switch, ctrl+x x or the close mark to dismiss), no
  // hand-rolled tab-switching Buttons needed.
  on('command.run', { command: 'pin' }, async ($, e) => {
    await ensure($)
    const text = String(e.args ?? '').trim()
    if (!text) return { text: 'Usage: /pin <message text>' }
    const lines = text.split('\n')
    const title = short(lines.find(l => l.trim().length > 0) ?? 'pinned message')
    const id = `p${Date.now().toString(36)}${Math.random().toString(36).slice(2, 5)}`
    const list = await loadPins($)
    const pin: Pin = { id, title, lines, highlightedRange: null, createdAt: await $.clock.now() }
    list.push(pin)
    await savePins($, list)
    await update($, pins, () => list)
    try {
      await $.ui.open({ id: PIN_PREFIX + id, title, focus: true })
    } catch (err) {
      return { text: `Pinned as "${title}", but couldn't open its tab: ${String((err as any)?.message ?? err)}` }
    }
    return { text: `Pinned as "${title}".` }
  })

  // Native close (ctrl+x x, the close mark, or this plugin's own dismiss
  // Button) all raise ui.close the same way — clean up the backing pin
  // either way so it doesn't linger as dead state on disk.
  on('ui.close', async ($, e, next) => {
    if (typeof e.id === 'string' && e.id.startsWith(PIN_PREFIX)) {
      const pinId = e.id.slice(PIN_PREFIX.length)
      const list = (await loadPins($)).filter(p => p.id !== pinId)
      await savePins($, list)
      await update($, pins, () => list)
    }
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    const src = e.source ?? 'user'
    myState = 'working'
    if (src === 'user' || src === 'sdk') {
      mySummary = short(e.prompt) // the ask, until the first action overrides it
      mySource = src
      myLastActivity = await $.clock.now() // real activity — a nudge/system turn is not
    } else {
      mySource = src // nudge/system turn: keep the last real summary, just heartbeat
    }
    await ensure($, e)
    await writeMine($)
    return next(e)
  })

  // The live signal: each tool call becomes this session's current action.
  on('tool.call', async ($, e, next) => {
    await ensure($, e)
    myState = 'working'
    lastAction = describeAction(e)
    mySummary = lastAction
    myLastActivity = await $.clock.now()
    await writeMine($)
    return next(e)
  })

  // A notification means the session wants the user's attention (a permission
  // prompt, a question, an idle nudge) — flag it red until work resumes.
  on('classic.Notification', async ($, e, next) => {
    await ensure($, e)
    const kind = String((e as any).notification_type ?? '').toLowerCase()
    if (!/compl|done|success|finish/.test(kind)) {
      myState = 'needs-you'
      const msg = clip((e as any).message, 60)
      if (msg) mySummary = msg
      await writeMine($)
    }
    return next(e)
  })

  // Turn finished → teammate-style status (throttled), state idle.
  on('turn.complete', async ($, e, next) => {
    await ensure($, e)
    myState = 'idle'
    const now = await $.clock.now()
    let newSummary = lastAction ? `idle · ${lastAction}` : 'idle'
    if (CFG.summaryModel !== 'off' && now - lastSummaryAt > Math.max(5, CFG.summaryEverySeconds) * 1000) {
      lastSummaryAt = now
      const s = await teammateStatus($)
      if (s) newSummary = s
    }
    mySummary = newSummary
    await writeMine($)
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    await ensure($, e)
    myState = 'ended'
    mySummary = 'ended'
    await writeMine($, true)
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    const { Box, Text, Button, Markdown, Input } = $.ui.resolve(e)

    // A pinned message's own tab — its own Pane id (PIN_PREFIX + pin id), so
    // this branch handles every pin pane, whichever one is in front.
    if (typeof e.requestId === 'string' && e.requestId.startsWith(PIN_PREFIX)) {
      const pinId = e.requestId.slice(PIN_PREFIX.length)
      const pinList = await read($, pins)
      const pin = pinList.find(p => p.id === pinId)
      if (!pin) {
        return (
          <Box borderStyle="round" borderColor="gray" paddingX={1}>
            <Text dimColor>Pin closed or not found.</Text>
          </Box>
        )
      }
      // Settled, don't retry: a markdown link in this terminal always draws
      // as literal "label (url)" text, confirmed with both file: and https:
      // schemes — it's how this terminal renders ANY link, not a scheme-
      // specific safety convention. Per-line click-via-link is a dead end
      // here. Pointing at a line instead moves a single pointer via two real
      // Buttons — the pointed-at line renders **bold** in the same markdown
      // text, so it stays visible regardless of content length without
      // adding one element (or one visible URL) per line.
      // highlightedRange is shared with the browser-based pin-preview
      // (pin-preview-server.py, over this exact file) — that side supports
      // real shift-click multi-line range select; the terminal side can
      // only ever move a single-line range (no mouse here), but still
      // renders a multi-line range correctly if the browser set one.
      const inRange = (i: number) => {
        const r = pin.highlightedRange
        return r !== null && i >= r.start && i <= r.end
      }
      const numWidth = String(Math.max(0, pin.lines.length - 1)).length
      const md = pin.lines
        .map((line, i) => {
          const num = String(i).padStart(numWidth)
          const text = line.length > 0 ? line : ' '
          return inRange(i) ? `**${num} → ${text}**` : `${num}   ${text}`
        })
        .join('\n')
      const movePointer = (delta: number) => async () => {
        const list2 = await loadPins($)
        const idx = list2.findIndex(p => p.id === pinId)
        if (idx < 0) return
        const cur = list2[idx]
        const base = cur.highlightedRange?.end ?? -1
        const nextIdx = Math.min(cur.lines.length - 1, Math.max(0, base + delta))
        list2[idx] = { ...cur, highlightedRange: { start: nextIdx, end: nextIdx } }
        await savePins($, list2)
        await update($, pins, () => list2)
      }
      const clearPointer = async () => {
        const list2 = await loadPins($)
        const idx = list2.findIndex(p => p.id === pinId)
        if (idx < 0) return
        list2[idx] = { ...list2[idx], highlightedRange: null }
        await savePins($, list2)
        await update($, pins, () => list2)
      }
      // ▲/▼ for fine adjustment; this jump box is the real fix for a long
      // pin — stepping one line at a time to reach line 79 of 160 isn't
      // usable. Clamped the same way movePointer is. Always collapses to a
      // single-line range — multi-line range-select is browser-only
      // (shift-click), since there's no mouse to drag-select with here.
      const jumpToLine = async (raw: string) => {
        const n = Number.parseInt(raw, 10)
        if (!Number.isFinite(n)) return
        const list2 = await loadPins($)
        const idx = list2.findIndex(p => p.id === pinId)
        if (idx < 0) return
        const cur = list2[idx]
        const clamped = Math.min(cur.lines.length - 1, Math.max(0, n))
        list2[idx] = { ...cur, highlightedRange: { start: clamped, end: clamped } }
        await savePins($, list2)
        await update($, pins, () => list2)
      }
      // herdr's own mouse UI (kept on, per instruction) swallows every
      // left-click before it reaches anything inside a pane — not a Claude
      // Code or library limitation, confirmed via herdr's config-reference
      // (ui.mouse_capture, no left-click passthrough exists, only a right-
      // click one). Keyboard input isn't mouse-captured, so hotkeys +
      // Tab/Enter sidestep it entirely: j/k/c/x fire once this pane has
      // keyboard focus (ctrl+x tab), no click needed at all.
      return (
        <Box flexDirection="column">
          <Box flexDirection="row">
            <Button role="dismiss" hotkey="x" onPress={() => void $.ui.close({ id: e.requestId })}>
              Close (x)
            </Button>
            <Button plain hotkey="k" label="▲" onPress={() => void movePointer(-1)()} />
            <Button plain hotkey="j" label="▼" onPress={() => void movePointer(1)()} />
            {pin.highlightedRange !== null && (
              <Button plain hotkey="c" label="clear" onPress={() => void clearPointer()} />
            )}
            <Input
              key={`pin-jump-${pinId}`}
              label="jump to line"
              placeholder={`0-${pin.lines.length - 1}`}
              onSubmit={value => void jumpToLine(value)}
            />
          </Box>
          <Box borderStyle="round" borderColor="gray" flexDirection="column" paddingX={1}>
            <Markdown key={`pin-md-${pinId}`} text={md} />
          </Box>
        </Box>
      )
    }

    if (e.requestId !== PANE) return next(e)

    const list = await read($, tickets) // read-only: no $.state.set during draw
    const taskList = await read($, tasks)
    const now = await $.clock.now()

    // This session's own task stack — a path from root to the active leaf,
    // with completed side-branches kept (dim) for memory after a gap.
    const byId = new Map(taskList.map(t => [t.id, t] as const))
    const depthOf = (t: TaskNode): number => {
      let d = 0
      let cur: TaskNode | undefined = t
      const seen = new Set<string>()
      while (cur?.parentId && !seen.has(cur.parentId)) {
        seen.add(cur.parentId)
        cur = byId.get(cur.parentId)
        d++
      }
      return d
    }
    const taskGlyph = (s: TaskStatus): { glyph: string; color: string } =>
      s === 'active' ? { glyph: '●', color: 'cyan' } : s === 'paused' ? { glyph: '◐', color: 'yellow' } : { glyph: '✓', color: 'gray' }
    // active (in progress) first, then paused (shelved), then done last.
    // Within paused, shallowest (closest to root) first, matching reading
    // order top-to-bottom as you'd unwind back out. Within done, most
    // recently closed first — most relevant to recall after a gap.
    const statusRank = (s: TaskStatus) => (s === 'active' ? 0 : s === 'paused' ? 1 : 2)
    const orderedTasks = [...taskList].sort((a, b) => {
      const r = statusRank(a.status) - statusRank(b.status)
      if (r !== 0) return r
      if (a.status === 'done') return (b.closedAt ?? b.createdAt) - (a.closedAt ?? a.createdAt)
      return depthOf(a) - depthOf(b)
    })

    const taskBox =
      orderedTasks.length > 0 ? (
        <Box borderStyle="round" borderColor="gray" flexDirection="column" paddingX={1}>
          <Text dimColor bold>
            Tasks
          </Text>
          {orderedTasks.map(t => {
            const depth = depthOf(t)
            const v = taskGlyph(t.status)
            return (
              <Box flexDirection="row">
                {depth > 0 && <Text dimColor>{'  '.repeat(depth)}</Text>}
                <Text color={v.color}>
                  {v.glyph}{' '}
                </Text>
                <Text dimColor={t.status === 'done'} bold={t.status === 'active'}>
                  {t.name}
                </Text>
              </Box>
            )
          })}
        </Box>
      ) : null

    if (list.length === 0) {
      return (
        <Box flexDirection="column">
          <Box borderStyle="round" borderColor="gray" paddingX={1}>
            <Text dimColor>{lastErr ? `no tickets — ${lastErr}` : 'No live sessions yet. Try /ticker.'}</Text>
          </Box>
          {taskBox}
        </Box>
      )
    }

    // Active = genuinely recent activity, or a needs-you alert (never demoted to
    // a one-liner regardless of age — it still needs a human to see it).
    const activeMs = Math.max(1, CFG.activeSeconds) * 1000
    const isActive = (t: Ticket) =>
      stateOf(t) === 'needs-you' || now - (t.lastActivity ?? t.updated) < activeMs
    const active = list.filter(isActive)
    const idle = list.filter(t => !isActive(t))

    // Active cards are ~2 rows each; idle rows are 1 each. Budget what's left
    // for idle after active + outer border/padding overhead, truncate with a count.
    const rows = e.viewport?.rows ?? 24
    const idleBudget = Math.max(0, rows - active.length * 2 - 3)
    const idleShown = idle.slice(0, idleBudget)
    const idleMore = idle.length - idleShown.length

    return (
      <Box flexDirection="column">
        <Box borderStyle="round" borderColor="gray" flexDirection="column" paddingX={1}>
          {active.map(t => {
            const me = t.key === myKey
            const v = view(stateOf(t))
            const accent = accentOf(t.key)
            const where = t.host && t.host !== 'local' ? t.host : ''
            return (
              <Box flexDirection="column">
                <Box flexDirection="row">
                  <Text color={v.color} bold>
                    {v.glyph}{' '}
                  </Text>
                  <Text color={accent} bold>
                    {t.label}
                  </Text>
                  {me && <Text dimColor> (you)</Text>}
                  {v.tag && <Text color="red" bold>{v.tag}</Text>}
                  <Text dimColor>
                    {'  '}
                    {where ? `@${where} · ` : ''}
                    {age(now, t.updated)}
                  </Text>
                </Box>
                <Text dimColor>{t.summary}</Text>
              </Box>
            )
          })}
          {active.length > 0 && idleShown.length > 0 && <Text dimColor>{'─'.repeat(24)}</Text>}
          {idleShown.map(t => {
            const me = t.key === myKey
            const v = view(stateOf(t))
            const accent = accentOf(t.key)
            const where = t.host && t.host !== 'local' ? t.host : ''
            return (
              <Box flexDirection="row">
                <Text color={v.color}>
                  {v.glyph}{' '}
                </Text>
                <Text color={accent}>{t.label}</Text>
                {me && <Text dimColor> (you)</Text>}
                <Text dimColor>
                  {'  '}
                  {where ? `@${where} · ` : ''}
                  {age(now, t.updated)}
                </Text>
              </Box>
            )
          })}
          {idleMore > 0 && <Text dimColor>  +{idleMore} more idle</Text>}
        </Box>
        {taskBox}
      </Box>
    )
  })
}
