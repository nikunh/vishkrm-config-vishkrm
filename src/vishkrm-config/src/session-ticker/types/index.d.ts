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
  ended?: boolean
}

declare module 'claude-code' {
  interface PluginState {
    'session-ticker': { tickets: Ticket[] }
  }
}
