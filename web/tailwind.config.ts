import type { Config } from 'tailwindcss'

const config: Config = {
  content: [
    './src/pages/**/*.{js,ts,jsx,tsx,mdx}',
    './src/components/**/*.{js,ts,jsx,tsx,mdx}',
    './src/app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        bg: {
          primary: '#0a0a0a',
          secondary: '#111111',
          card: '#151515',
          elevated: '#1a1a1a',
        },
        border: {
          subtle: '#222222',
          DEFAULT: '#2a2a2a',
        },
        text: {
          primary: '#e0e0e0',
          secondary: '#888888',
          muted: '#555555',
        },
        accent: {
          DEFAULT: '#dc2626',
          light: '#ef4444',
          hover: '#b91c1c',
        },
      },
      fontFamily: {
        mono: ['var(--font-jetbrains)', 'JetBrains Mono', 'Fira Code', 'monospace'],
        sans: ['var(--font-inter)', 'Inter', 'system-ui', 'sans-serif'],
      },
    },
  },
  plugins: [],
}

export default config
