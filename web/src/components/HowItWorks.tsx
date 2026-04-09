const steps = [
  {
    number: '1',
    title: 'Your AI agent runs on your server',
    description:
      'Start Codex or Claude Code inside a tmux session on your remote Linux server. It keeps running even when you close your laptop or disconnect from SSH. You can watch multiple panes — one per agent — simultaneously.',
  },
  {
    number: '2',
    title: 'A watcher detects approval prompts',
    description:
      'A lightweight monitoring script polls the tmux output. When Codex or Claude Code asks for permission to run a shell command, the watcher detects which agent is asking, queues the right keystroke, and sends a push notification via Pushover.',
  },
  {
    number: '3',
    title: 'You tap approve on your Apple Watch',
    description:
      'An iOS Shortcut on your watch sends a secure webhook request back to the server. The webhook injects the correct approval keystroke into tmux — y for Codex, 1 for Claude Code — and your agent continues working.',
  },
]

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="py-20 sm:py-28 border-t border-border-subtle">
      <div className="mx-auto max-w-5xl px-6">
        <div className="text-center mb-16">
          <h2 className="section-heading">
            <span className="text-accent font-mono">#</span> How It Works
          </h2>
          <p className="section-subheading">
            Three steps from Codex prompt to approval on your wrist
          </p>
        </div>

        <div className="space-y-8">
          {steps.map((step) => (
            <div key={step.number} className="flex gap-6 items-start">
              <div className="flex-shrink-0 w-12 h-12 flex items-center justify-center border border-accent/40 rounded-full bg-accent/10">
                <span className="font-mono text-accent text-lg font-bold">{step.number}</span>
              </div>
              <div className="flex-1 min-w-0 pt-1">
                <h3 className="font-mono text-lg font-semibold text-text-primary mb-2">
                  {step.title}
                </h3>
                <p className="text-text-secondary text-sm leading-relaxed">
                  {step.description}
                </p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
