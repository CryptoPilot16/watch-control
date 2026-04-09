const steps = [
  {
    number: '01',
    title: 'Find your Tailscale hostname',
    description: 'On your server, run the command below. Your hostname looks like \`my-server.tail1234.ts.net\`. Copy it — you\'ll need it for the shortcut URL.',
    code: `tailscale status --json | python3 -c "import sys,json; print(json.load(sys.stdin)['Self']['DNSName'])"`,
  },
  {
    number: '02',
    title: 'Build your approve URL',
    description: 'Combine your hostname with the approve endpoint and your secret. This is the URL the shortcut will call.',
    code: `https://<your-hostname>/approve?secret=<your-APPROVE_SECRET>

# Example:
# https://my-server.tail1234.ts.net/approve?secret=abc123`,
  },
  {
    number: '03',
    title: 'Create the iOS Shortcut',
    description: (
      <ol className="list-none space-y-1.5 text-text-secondary text-sm">
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">1.</span>Open the <strong className="text-text-primary font-medium">Shortcuts</strong> app on your iPhone</li>
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">2.</span>Tap <strong className="text-text-primary font-medium">+</strong> to create a new shortcut</li>
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">3.</span>Search for and add the <strong className="text-text-primary font-medium">Get Contents of URL</strong> action</li>
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">4.</span>Paste your approve URL from step 2 into the URL field</li>
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">5.</span>Name the shortcut <strong className="text-text-primary font-medium">Approve Codex</strong></li>
      </ol>
    ),
  },
  {
    number: '04',
    title: 'Add it to your Apple Watch',
    description: (
      <ol className="list-none space-y-1.5 text-text-secondary text-sm">
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">1.</span>Open the shortcut you just created and tap the <strong className="text-text-primary font-medium">info (ⓘ)</strong> icon</li>
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">2.</span>Toggle on <strong className="text-text-primary font-medium">Show on Apple Watch</strong></li>
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">3.</span>On your watch, open the <strong className="text-text-primary font-medium">Shortcuts</strong> app — it appears immediately</li>
        <li className="flex gap-2"><span className="text-accent font-mono text-xs flex-shrink-0 mt-0.5">4.</span>Optionally add it as a <strong className="text-text-primary font-medium">complication</strong> for one-tap access from your watch face</li>
      </ol>
    ),
  },
]

export default function WatchSetup() {
  return (
    <section id="watch-setup" className="py-20 sm:py-28 border-t border-border-subtle">
      <div className="mx-auto max-w-5xl px-6">
        <div className="text-center mb-16">
          <h2 className="section-heading">
            <span className="text-accent font-mono">⌚</span> Watch Setup
          </h2>
          <p className="section-subheading">
            Wire up your Apple Watch — one shortcut, one tap
          </p>
        </div>

        <div className="space-y-10">
          {steps.map((step) => (
            <div key={step.number} className="flex gap-6 items-start">
              <div className="flex-shrink-0 w-12 h-12 flex items-center justify-center border border-border-subtle rounded-lg bg-bg-card">
                <span className="font-mono text-accent text-sm font-bold">{step.number}</span>
              </div>
              <div className="flex-1 min-w-0">
                <h3 className="font-mono text-lg font-semibold text-text-primary mb-3">
                  {step.title}
                </h3>
                {step.code && (
                  <div className="code-block mb-3">
                    <pre className="text-sm leading-relaxed whitespace-pre-wrap">
                      <code>{step.code}</code>
                    </pre>
                  </div>
                )}
                <div className="leading-relaxed">
                  {typeof step.description === 'string' ? (
                    <p className="text-text-secondary text-sm">{step.description}</p>
                  ) : (
                    step.description
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>

        {/* Tip */}
        <div className="mt-12 p-5 border border-border-subtle rounded-lg bg-bg-card">
          <h4 className="font-mono text-sm font-semibold text-accent mb-2">Tip — add a Deny shortcut too</h4>
          <p className="text-text-secondary text-sm leading-relaxed">
            Repeat the steps above with <code className="font-mono text-xs text-accent bg-bg-secondary px-1.5 py-0.5 rounded">/deny</code> instead of <code className="font-mono text-xs text-accent bg-bg-secondary px-1.5 py-0.5 rounded">/approve</code>. Name it <strong className="text-text-primary font-medium">Deny Codex</strong> and add it to your watch as well — useful when you want to reject a command without opening your laptop.
          </p>
        </div>
      </div>
    </section>
  )
}
