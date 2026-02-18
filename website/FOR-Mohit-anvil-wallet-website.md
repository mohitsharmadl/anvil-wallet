# FOR-Mohit: Anvil Wallet Landing Page

## What Is This?

A single-file landing page for **anvilwallet.com** -- the public-facing marketing site for the Anvil Wallet project. It is a static HTML page with all CSS inlined and minimal vanilla JavaScript. No build step, no frameworks, no dependencies beyond Google Fonts.

Think of it like a really well-designed GitHub README, but as a website. The vibe is Linear.app meets Vercel -- dark, technical, premium. It targets developers and crypto-savvy users who care about security and open source.

## Technical Architecture

```
website/
  index.html   <-- Everything lives here. CSS in <style>, JS in <script>.
```

That's it. One file. Deploy it to Cloudflare Pages, Vercel, Netlify, or literally any static hosting by pointing it at this directory.

## How It Works

- **No build step.** Open the HTML file in a browser and it works.
- **Google Fonts** (Inter + JetBrains Mono) loaded via CDN `<link>` tags.
- **Scroll animations** use IntersectionObserver (native browser API). Elements with `.reveal` class fade in when they enter the viewport.
- **Nav** gets a border on scroll via a scroll listener. Mobile menu is a simple toggle.
- **No tracking, no analytics, no cookies.** Consistent with the wallet's zero-telemetry promise.

## Design Decisions

| Choice | Why |
|--------|-----|
| Single HTML file | Zero complexity for deployment. No build tools, no Node.js needed. |
| Inline CSS (not external) | One file = one request. Keeps deployment trivial. |
| CSS-only animations | No Framer Motion or GSAP -- keeps the page fast and dependency-free. |
| IntersectionObserver | Native browser API for scroll reveals. No scroll libraries. |
| SVG icons inline | No icon library CDN to load. Icons are tiny and load instantly. |
| Dark theme (#0a0e17) | Matches the "forged metal" brand. High contrast amber on dark navy. |
| JetBrains Mono for code | The code snippet section looks legit, not like a toy. |

## Sections

1. **Hero** -- Headline, tagline, subtitle, GitHub CTA + disabled App Store button, stat badges
2. **Why Rust** -- Four reasons with icons + a real code snippet showing `ZeroizeOnDrop`
3. **Multi-Chain** -- 9 blockchain cards in a responsive grid
4. **16 Security Layers** -- Grouped into Hardware/Encryption/Protection/Validation, with the double-encryption callout
5. **Open Source** -- Stats (241 tests, 5 crates, 17k+ LOC, MIT), quote, GitHub link
6. **Architecture** -- Visual diagram of SwiftUI -> UniFFI -> Rust Core with the 5 crate boxes
7. **Footer** -- Brand, social links (GitHub, Twitter, Instagram), MIT license

## Deployment

For Cloudflare Pages:
1. Connect the `anvil-wallet` repo to Cloudflare Pages
2. Set build output directory to `website/`
3. No build command needed (it's static)
4. Set custom domain to `anvilwallet.com`

For any other host (Vercel, Netlify, etc.):
- Just point to the `website/` directory, no build step.

## What to Update Later

- **OG image**: The `og:image` meta tag points to a placeholder. Create an actual 1200x630 image and upload it.
- **Favicon**: Currently uses an inline SVG data URI. Replace with a proper `.ico` or `.png` when branding is finalized.
- **App Store button**: Currently disabled/greyed out. Enable it when the app is actually on the App Store.
- **Stats**: If test count, LOC, or crate count changes, update the numbers in the hero badges and Open Source section.
- **Social links**: Twitter and Instagram link to `@anvilwallet`. Make sure those accounts exist.

## Lessons Learned

- Inline SVG icons are way better than icon font libraries for a single-page site. Zero extra requests, perfect scaling, and you can style them with CSS.
- `backdrop-filter: blur()` on the nav gives that premium frosted glass effect but needs the `-webkit-` prefix for Safari.
- `clamp()` for font sizes is the modern way to do responsive typography -- no media queries needed for text sizing.
- The code block with syntax highlighting is pure HTML/CSS (span classes for colors). No Prism.js or Highlight.js needed for a single snippet.
