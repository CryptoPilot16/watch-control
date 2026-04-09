import type { Metadata } from 'next'
import { JetBrains_Mono, Inter } from 'next/font/google'
import Header from '@/components/Header'
import Footer from '@/components/Footer'
import './globals.css'

const jetbrainsMono = JetBrains_Mono({
  subsets: ['latin'],
  variable: '--font-jetbrains',
  display: 'swap',
})

const inter = Inter({
  subsets: ['latin'],
  variable: '--font-inter',
  display: 'swap',
})

export const metadata: Metadata = {
  title: 'Watch Control — Approve Codex & Claude Code Commands from Your Apple Watch',
  description:
    'Approve Codex and Claude Code commands from your Apple Watch. Your agent runs on a remote server in tmux — a watcher auto-detects prompts and sends push notifications so you can approve from anywhere.',
  icons: {
    icon: '/favicon.svg',
  },
  openGraph: {
    title: 'Watch Control — Approve Codex & Claude Code Commands from Your Apple Watch',
    description:
      'Approve Codex and Claude Code commands from your Apple Watch — no need to stay at your laptop. Push notifications via Pushover, secure webhook via Tailscale.',
    type: 'website',
    url: 'https://watch-control.clawnux.com',
  },
  twitter: {
    card: 'summary',
    title: 'Watch Control',
    description: 'Approve Codex commands from your Apple Watch — no need to stay at your laptop.',
    creator: '@cryptopilot16',
  },
  metadataBase: new URL('https://watch-control.clawnux.com'),
}

export default function RootLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <html lang="en" className={`${jetbrainsMono.variable} ${inter.variable}`}>
      <body className="bg-bg-primary text-text-primary font-sans antialiased">
        <Header />
        <main className="pt-16">
          {children}
        </main>
        <Footer />
      </body>
    </html>
  )
}
