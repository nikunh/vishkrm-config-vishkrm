import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Ticket, TicketState } from '../types'

const PANE = 'session-ticker'

const tickets = atom({ plugin: 'session-ticker', key: 'tickets' } as const, [] as Ticket[])

// Config (filled from userConfig in register; defaults match the manifest).
let CFG = { summaryModel: 'haiku', summaryEverySeconds: 45, ttlMinutes: 6, maxCards: 0 }

// This session's own ticket, kept in module vars (re-seeded on every load).
let myKey = '' // stable filename key (sanitized cwd) — no event needed
let myId = '' // real session id when an event gives us one, else myKey
let myCwd = ''
let mySummary = 'started session'
let mySource = 'startup'
let myState: TicketState = 'working'
let lastAction = '' // last tool action this session performed
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
  const w = s.replace(/\s+/g, ' ').trim().split(' ').filter(Boolean)
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
    const host = (await $.env.get('SHELLINATOR_HOST')) ?? 'local'
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
  const live = list.filter(t => !t.ended && stateOf(t) !== 'ended' && now - t.updated < ttl)
  live.sort((a, b) => rank(stateOf(a)) - rank(stateOf(b)) || b.updated - a.updated)
  await update($, tickets, () => live)
  const need = live.filter(t => stateOf(t) === 'needs-you').length
  $.ui.status(
    live.length ? `◈ ${live.length} live${need ? ` · ${need} need you` : ''}` : undefined,
  )
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
  if (!myKey) myKey = sanitize(myCwd)
  if (!myId) myId = myKey
  if (!booted) {
    booted = true
    await writeMine($)
    $.clock.every(30_000, () => void writeMine($))
    $.clock.every(5_000, () => void refresh($))
  }
}

export const register: Register = (on, options) => {
  CFG = {
    summaryModel: String(options?.summaryModel ?? 'haiku'),
    summaryEverySeconds: Number(options?.summaryEverySeconds ?? 45),
    ttlMinutes: Number(options?.ttlMinutes ?? 6),
    maxCards: Number(options?.maxCards ?? 0),
  }

  on('session.start', async ($, e, next) => {
    mySummary = e.source === 'resume' ? 'resumed session' : 'started session'
    mySource = e.source
    myState = 'working'
    await ensure($, e)
    await $.command.register({ name: 'ticker', description: 'Open the live session ticker' })
    void $.ui.open({ id: PANE, title: 'Session ticker' })
    void refresh($)
    return next(e)
  })

  on('command.run', { command: 'ticker' }, async $ => {
    await ensure($)
    await $.ui.open({ id: PANE, title: 'Session ticker' })
    await refresh($)
    return { text: `Session ticker opened.${lastErr ? ' (err: ' + lastErr + ')' : ''}` }
  })

  on('prompt.submit', async ($, e, next) => {
    const src = e.source ?? 'user'
    myState = 'working'
    if (src === 'user' || src === 'sdk') {
      mySummary = short(e.prompt) // the ask, until the first action overrides it
      mySource = src
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

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = await read($, tickets) // read-only: no $.state.set during draw
    const now = await $.clock.now()
    const fit = Math.max(1, Math.floor(((e.viewport?.rows ?? 24) - 2) / 4))
    const room = CFG.maxCards > 0 ? Math.min(CFG.maxCards, fit) : fit

    if (list.length === 0) {
      return (
        <Box borderStyle="round" borderColor="gray" paddingX={1}>
          <Text dimColor>{lastErr ? `no tickets — ${lastErr}` : 'No live sessions yet. Try /ticker.'}</Text>
        </Box>
      )
    }

    return (
      <Box flexDirection="column">
        {list.slice(0, room).map(t => {
          const me = t.key === myKey
          const s = stateOf(t)
          const v = view(s)
          const accent = accentOf(t.key)
          const borderColor = v.border ?? accent
          const borderStyle = v.border === 'red' || me ? 'bold' : 'round'
          const where = t.host && t.host !== 'local' ? t.host : ''
          return (
            <Box borderStyle={borderStyle} borderColor={borderColor} flexDirection="column" paddingX={1}>
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
      </Box>
    )
  })
}
