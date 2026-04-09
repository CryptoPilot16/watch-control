export default function Infrastructure() {
  return (
    <section id="infrastructure" className="py-20 sm:py-28 border-t border-border-subtle">
      <div className="mx-auto max-w-5xl px-6">
        <div className="text-center mb-16">
          <h2 className="section-heading">
            <span className="text-accent font-mono">@</span> Infrastructure
          </h2>
          <p className="section-subheading">
            What runs where
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div className="p-6 border border-border-subtle rounded-lg bg-bg-card">
            <h3 className="font-mono text-sm font-semibold text-accent mb-3">Landing Page</h3>
            <p className="text-text-secondary text-sm leading-relaxed mb-3">
              This site is a static Next.js app, self-hosted and served via Caddy.
            </p>
            <code className="text-xs font-mono text-text-muted bg-bg-secondary px-2 py-1 rounded block">
              https://watch-control.clawnux.com
            </code>
          </div>

          <div className="p-6 border border-border-subtle rounded-lg bg-bg-card">
            <h3 className="font-mono text-sm font-semibold text-accent mb-3">Approval Endpoint</h3>
            <p className="text-text-secondary text-sm leading-relaxed mb-3">
              The webhook runs privately on your Linux server, accessible only through your Tailscale network. It is never exposed to the public internet.
            </p>
            <div className="flex items-center gap-2 text-xs text-green-500">
              <span>✓</span>
              <span>Tailnet-only access — no public ports</span>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
