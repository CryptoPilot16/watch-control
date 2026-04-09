import Hero from '@/components/Hero'
import HowItWorks from '@/components/HowItWorks'
import WhyItMatters from '@/components/WhyItMatters'
import TechOverview from '@/components/TechOverview'
import QuickStart from '@/components/QuickStart'
import WatchSetup from '@/components/WatchSetup'
import Architecture from '@/components/Architecture'
import Infrastructure from '@/components/Infrastructure'

export default function Home() {
  return (
    <>
      <Hero />
      <HowItWorks />
      <WhyItMatters />
      <TechOverview />
      <QuickStart />
      <WatchSetup />
      <Architecture />
      <Infrastructure />
    </>
  )
}
