export type TicketState = 'working' | 'idle' | 'needs-you' | 'ended'

export type Ticket = {
  key: string
  sessionId: string
  label: string
  host: string
  summary: string
  source: string
  state: TicketState
  updated: number
  lastActivity?: number
  ended?: boolean
}

export type TaskStatus = 'active' | 'paused' | 'done'

// One entry in this session's own work stack. parentId chains form the
// nesting: the single 'active' leaf, its parentId ancestors are 'paused',
// everything else is 'done'. Written directly by the model (Write/Edit),
// never by this plugin — see the session-task-stack skill.
export type TaskNode = {
  id: string
  name: string
  parentId: string | null
  status: TaskStatus
  createdAt: number
  closedAt?: number | null
}

// A pinned chat message, parked as its own tab (its own Pane id, `pin:<id>`)
// next to the ticker, and also viewable in the browser-based pin-preview
// (pin-preview-server.py) over the exact same file — either side can set
// highlightedRange, both re-read it. inclusive line indices, start<=end;
// a single line is {start:n, end:n}. Content is written directly by the
// model (Write/Edit), same convention as TaskNode.
export type Pin = {
  id: string
  title: string
  lines: string[]
  highlightedRange: { start: number; end: number } | null
  createdAt: number
}

declare module 'claude-code' {
  interface PluginState {
    'session-ticker': { tickets: Ticket[]; tasks: TaskNode[]; pins: Pin[] }
  }
}
