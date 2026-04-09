const technologies = [
  {
    name: 'Codex or Claude Code in tmux',
    description: 'Either agent runs inside a persistent tmux session on your Linux server so it survives SSH disconnects. Watch multiple panes at once.',
  },
  {
    name: 'codex_watch.sh',
    description: 'Polls tmux output for approval prompts. Auto-detects whether Codex or Claude Code is asking and queues the correct keystroke (y or 1).',
  },
  {
    name: 'approve_webhook.py',
    description: 'A lightweight Python HTTP server that validates a shared secret and injects the queued keystroke into the right tmux pane.',
  },
  {
    name: 'Tailscale Serve',
    description: 'Exposes the webhook over your private tailnet with HTTPS — no public ports, no port forwarding.',
  },
  {
    name: 'Apple Watch Shortcut',
    description: 'An iOS Shortcut that sends a single GET request to the webhook when you tap Approve on your watch.',
  },
  {
    name: 'Pushover',
    description: 'Delivers instant push notifications to your iPhone and Apple Watch when Codex needs a decision.',
  },
]

export default function TechOverview() {
  return (
    <section id="technology" className="py-20 sm:py-28 border-t border-border-subtle">
      <div className="mx-auto max-w-5xl px-6">
        <div className="text-center mb-16">
          <h2 className="section-heading">
            <span className="text-accent font-mono">&amp;</span> Technology Overview
          </h2>
          <p className="section-subheading">
            Six components. No cloud services beyond notifications.
          </p>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {technologies.map((tech) => (
            <div
              key={tech.name}
              className="p-5 border border-border-subtle rounded-lg bg-bg-card hover:border-border transition-colors"
            >
              <h3 className="font-mono text-sm font-semibold text-accent mb-2">
                {tech.name}
              </h3>
              <p className="text-text-secondary text-xs leading-relaxed">
                {tech.description}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
