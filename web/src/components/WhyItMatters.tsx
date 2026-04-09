const scenarios = [
  {
    title: 'Making coffee',
    description:
      'Step away from your desk without pausing your agent. Approve commands from your wrist while your hands are busy.',
    icon: '☕',
  },
  {
    title: 'In a meeting',
    description:
      'Your agent keeps working in the background. A quick glance at your watch, a tap, and the build continues — no one notices.',
    icon: '🤝',
  },
  {
    title: 'On the go',
    description:
      'Leave the house entirely. Your server runs the agent, your watch handles approvals. Code gets written while you walk the dog.',
    icon: '🚶',
  },
  {
    title: 'Overnight builds',
    description:
      'Kick off a long task before bed. When your agent needs approval at 2 AM, your watch buzzes gently — tap and go back to sleep.',
    icon: '🌙',
  },
]

export default function WhyItMatters() {
  return (
    <section id="why-it-matters" className="py-20 sm:py-28 border-t border-border-subtle">
      <div className="mx-auto max-w-5xl px-6">
        <div className="text-center mb-16">
          <h2 className="section-heading">
            <span className="text-accent font-mono">~</span> Why It Matters
          </h2>
          <p className="section-subheading">
            Stop babysitting your terminal. Approve from anywhere.
          </p>
        </div>

        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          {scenarios.map((scenario) => (
            <div
              key={scenario.title}
              className="p-6 border border-border-subtle rounded-lg bg-bg-card hover:border-border transition-colors"
            >
              <span className="text-2xl mb-3 block" role="img" aria-label={scenario.title}>
                {scenario.icon}
              </span>
              <h3 className="font-mono text-base font-semibold text-text-primary mb-2">
                {scenario.title}
              </h3>
              <p className="text-text-secondary text-sm leading-relaxed">
                {scenario.description}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
