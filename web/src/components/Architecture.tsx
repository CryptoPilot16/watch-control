const components = [
  {
    name: 'Codex (tmux)',
    description: 'Persistent execution environment — keeps running when SSH disconnects',
    icon: '⌨️',
  },
  {
    name: 'codex_watch.sh',
    description: 'Polling loop that monitors tmux output for approval prompts',
    icon: '👁️',
  },
  {
    name: 'approve_webhook.py',
    description: 'HTTP server that validates secrets and injects keystrokes into tmux',
    icon: '🔗',
  },
  {
    name: 'Tailscale Serve',
    description: 'Exposes webhook over your tailnet via *.ts.net HTTPS — no public ports',
    icon: '🔒',
  },
  {
    name: 'Pushover',
    description: 'Notification delivery to your iPhone and Apple Watch',
    icon: '🔔',
  },
  {
    name: 'Apple Watch',
    description: 'One-tap approval via iOS Shortcuts — runs a simple GET request',
    icon: '⌚',
  },
]

const endpoints = [
  { path: '/approve', method: 'GET/POST', description: 'Injects the queued approval keystroke into tmux' },
  { path: '/approve2', method: 'GET/POST', description: 'Alias for /approve' },
  { path: '/deny', method: 'GET/POST', description: 'Sends Escape to the queued tmux pane' },
]

const flowSteps = [
  { step: 1, label: 'Agent needs approval', color: 'text-text-primary' },
  { step: 2, label: 'Watcher detects prompt', color: 'text-text-primary' },
  { step: 3, label: 'Pushover sends notification', color: 'text-yellow-500' },
  { step: 4, label: 'You tap Approve on watch', color: 'text-green-500' },
  { step: 5, label: 'Webhook injects keystroke', color: 'text-accent' },
  { step: 6, label: 'Agent continues', color: 'text-green-500' },
]

export default function Architecture() {
  return (
    <section id="architecture" className="py-20 sm:py-28 border-t border-border-subtle">
      <div className="mx-auto max-w-5xl px-6">
        <div className="text-center mb-16">
          <h2 className="section-heading">
            <span className="text-accent font-mono">#</span> Architecture
          </h2>
          <p className="section-subheading">
            The approval flow from your AI agent to your wrist — step by step
          </p>
        </div>

        {/* Flow diagram */}
        <div className="mb-16">
          <div className="flex flex-wrap justify-center gap-2 sm:gap-0 items-center">
            {flowSteps.map((item, i) => (
              <div key={item.step} className="flex items-center">
                <div className="flex items-center gap-2 px-3 py-2 border border-border-subtle rounded-lg bg-bg-card">
                  <span className="font-mono text-xs text-text-muted">{item.step}</span>
                  <span className={`text-xs sm:text-sm font-mono ${item.color}`}>{item.label}</span>
                </div>
                {i < flowSteps.length - 1 && (
                  <span className="text-text-muted mx-1 hidden sm:inline font-mono">→</span>
                )}
              </div>
            ))}
          </div>
        </div>

        {/* Components grid */}
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 mb-16">
          {components.map((component) => (
            <div
              key={component.name}
              className="p-5 border border-border-subtle rounded-lg bg-bg-card hover:border-border transition-colors"
            >
              <div className="flex items-start gap-3">
                <span className="text-2xl flex-shrink-0" role="img" aria-label={component.name}>
                  {component.icon}
                </span>
                <div>
                  <h3 className="font-mono text-sm font-semibold text-text-primary">
                    {component.name}
                  </h3>
                  <p className="text-text-secondary text-xs mt-1 leading-relaxed">
                    {component.description}
                  </p>
                </div>
              </div>
            </div>
          ))}
        </div>

        {/* Security + Endpoints */}
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div className="p-5 border border-border-subtle rounded-lg bg-bg-card">
            <h3 className="font-mono text-sm font-semibold text-accent mb-3">Security Model</h3>
            <ul className="space-y-2 text-sm text-text-secondary">
              <li className="flex items-start gap-2">
                <span className="text-green-500 mt-0.5">✓</span>
                Webhook stays local — no public port exposure
              </li>
              <li className="flex items-start gap-2">
                <span className="text-green-500 mt-0.5">✓</span>
                Tailscale HTTPS encrypts over your tailnet
              </li>
              <li className="flex items-start gap-2">
                <span className="text-green-500 mt-0.5">✓</span>
                Shared secret required via <code className="font-mono text-xs text-accent">?secret=</code> or <code className="font-mono text-xs text-accent">X-Secret</code> header
              </li>
            </ul>
          </div>

          <div className="p-5 border border-border-subtle rounded-lg bg-bg-card">
            <h3 className="font-mono text-sm font-semibold text-accent mb-3">Webhook Endpoints</h3>
            <div className="space-y-2">
              {endpoints.map((ep) => (
                <div key={ep.path} className="flex items-center gap-3 text-sm">
                  <code className="font-mono text-xs text-accent bg-bg-secondary px-2 py-0.5 rounded">
                    {ep.path}
                  </code>
                  <span className="text-text-secondary text-xs">{ep.description}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
