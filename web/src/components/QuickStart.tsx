const prereqs = [
  { label: 'Linux server', detail: 'with tmux and Python 3 installed' },
  { label: 'Pushover account', detail: 'free — create an app token at pushover.net' },
  { label: 'Tailscale', detail: 'installed and authenticated on your server' },
  { label: 'Apple Watch', detail: 'paired with an iPhone that has the Shortcuts app' },
]

const steps = [
  {
    number: '01',
    title: 'Clone the repo',
    code: `git clone https://github.com/CryptoPilot16/watch-control.git
cd watch-control`,
  },
  {
    number: '02',
    title: 'Configure environment',
    code: `cp .env.example .env

# Edit .env and set:
APPROVE_SECRET=your-secret-here
PUSHOVER_APP_TOKEN=your-pushover-token
PUSHOVER_USER_KEY=your-pushover-key`,
  },
  {
    number: '03',
    title: 'Start the services',
    code: `bash ./restart.sh

# Or start manually:
# Terminal 1: python3 approve_webhook.py
# Terminal 2: bash ./codex_watch.sh`,
  },
  {
    number: '04',
    title: 'Expose via Tailscale Serve',
    code: `# Run once — makes the webhook available on your tailnet
tailscale serve --bg localhost:8787

# Verify your tailnet URL:
tailscale status --json | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'])"`,
  },
]

export default function QuickStart() {
  return (
    <section id="quickstart" className="py-20 sm:py-28 border-t border-border-subtle">
      <div className="mx-auto max-w-5xl px-6">
        <div className="text-center mb-16">
          <h2 className="section-heading">
            <span className="text-accent font-mono">$</span> Quick Start
          </h2>
          <p className="section-subheading">
            Three commands to get remote Codex approval running
          </p>
        </div>

        {/* Prerequisites */}
        <div className="mb-12 p-5 border border-border rounded-lg bg-bg-card">
          <h3 className="font-mono text-sm font-semibold text-text-primary mb-4">
            Before you start
          </h3>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            {prereqs.map((p) => (
              <div key={p.label} className="flex items-start gap-2 text-sm">
                <span className="text-accent mt-0.5 flex-shrink-0">✓</span>
                <span>
                  <span className="font-mono text-text-primary text-xs">{p.label}</span>
                  <span className="text-text-muted text-xs ml-1">— {p.detail}</span>
                </span>
              </div>
            ))}
          </div>
        </div>

        <div className="space-y-8">
          {steps.map((step) => (
            <div key={step.number} className="flex gap-6 items-start">
              <div className="flex-shrink-0 w-12 h-12 flex items-center justify-center border border-border-subtle rounded-lg bg-bg-card">
                <span className="font-mono text-accent text-sm font-bold">{step.number}</span>
              </div>
              <div className="flex-1 min-w-0">
                <h3 className="font-mono text-lg font-semibold text-text-primary mb-3">
                  {step.title}
                </h3>
                <div className="code-block">
                  <pre className="text-sm leading-relaxed whitespace-pre-wrap">
                    <code>{step.code}</code>
                  </pre>
                </div>
              </div>
            </div>
          ))}
        </div>

        <div className="mt-12 p-4 border border-border-subtle rounded-lg bg-bg-card">
          <h4 className="font-mono text-sm font-semibold text-accent mb-2">Environment Variables</h4>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-sm">
            <div>
              <code className="text-accent font-mono text-xs">APPROVE_SECRET</code>
              <span className="text-text-secondary ml-2 text-xs">Shared secret for webhook auth</span>
            </div>
            <div>
              <code className="text-accent font-mono text-xs">PUSHOVER_APP_TOKEN</code>
              <span className="text-text-secondary ml-2 text-xs">Pushover application token</span>
            </div>
            <div>
              <code className="text-accent font-mono text-xs">PUSHOVER_USER_KEY</code>
              <span className="text-text-secondary ml-2 text-xs">Pushover user key for alerts</span>
            </div>
            <div>
              <code className="text-accent font-mono text-xs">TMUX_SESSION</code>
              <span className="text-text-secondary ml-2 text-xs">Target pane (default: codex:0.0)</span>
            </div>
            <div>
              <code className="text-accent font-mono text-xs">APPROVE_PORT</code>
              <span className="text-text-secondary ml-2 text-xs">Webhook port (default: 8787)</span>
            </div>
            <div>
              <code className="text-accent font-mono text-xs">COOLDOWN_SECONDS</code>
              <span className="text-text-secondary ml-2 text-xs">Min time between notifications (30)</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
