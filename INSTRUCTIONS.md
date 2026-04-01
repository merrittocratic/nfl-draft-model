# Merrittocracy — Project Instructions

## What This Is
A sports analytics brand built on a foundation of data-driven NFL Draft
analysis. The 2026 NFL Draft model is the launch vehicle, but the long-term
goal is a broader sports analytics business. Every technical and content
decision should be made with that trajectory in mind.

## Background
- Director-level data scientist with deep R expertise (tidymodels, Shiny, dplyr)
- Strong NFL domain knowledge, follows the draft closely
- Primary AI tool: Claude Code (this machine is the modeling machine)
- Future: OpenClaw on Mac Mini M4 — post-draft, separate project
- LLM APIs available: Claude, ChatGPT, Gemini (language-agnostic by design)
- Day job: Florida Blue (health insurance) — keep completely separate from this project

## Brand Stack
| Platform    | Handle / Name                     | URL                                        |
|-------------|-----------------------------------|--------------------------------------------|
| X (Twitter) | @Merrittocratic                   | x.com/Merrittocratic                       |
| Email       | themerrittocratic@gmail.com       |                                             |
| Substack    | @themerrittocracy / Merrittocracy | themerrittocracy.substack.com              |
| Domain      | merrittocracy.org                 | merrittocracy.org                           |
| GitHub Org  | merrittocratic                    | github.com/merrittocratic                  |
| GitHub Repo | nfl-draft-model                   | github.com/merrittocratic/nfl-draft-model  |

---

## Target Audience
**Mixed — two layers:**
- **Analytics community:** Data scientists and sports analytics people interested
  in methodology, code, and modeling decisions. They care about the "how" — show
  the R code, explain the feature engineering, share the GitHub repo.
- **NFL fans:** People who follow the draft and want smarter analysis than talking
  heads provide. They care about the "what" — which prospects boom, which bust,
  and why the conventional wisdom might be wrong.

Content should serve both simultaneously: lead with the accessible take, make the
methodology available for those who want to dig in.

---

## Tech Stack
- **Modeling:** R + tidymodels + nflreadr + XGBoost + TabPFN + TabNet
- **Visualization:** Observable / D3.js for interactive content embeds
- **Content platforms:** X (short takes, data viz, threads) + Substack (deep dives, methodology, mock drafts)
- **Automation (future/separate):** OpenClaw on Mac Mini M4 — not part of the 2026 draft project
- **Code hosting:** Public GitHub repo for credibility with analytics community
- **Style:** Written > video for now. Revisit YouTube after audience is established.

---

## The Model

### Outcome Variable
- **Primary:** Draft-pick-adjusted Career Approximate Value (4-year window)
- Compute expected AV per pick bin using historical averages, model the residual
  (actual AV minus expected AV)
- **Classification labels** derived from regression output:
  - Boom: standardized residual > 1
  - Bust: standardized residual < -1
  - Expected: everything else
- **Rationale:** Regression-first gives more flexibility to define thresholds
  after the fact and produces richer output for content than pure classification

### 7 Tiered Sub-Models
| Group  | Positions | Rationale |
|--------|-----------|-----------|
| qb     | QB        | Unique evaluation features (passing production, arm metrics) |
| wr_te  | WR, TE    | Shared receiving/route-running evaluation DNA |
| dl     | EDGE, IDL | Pass rush production + athletic testing |
| ol     | OT, IOL   | Blocking metrics, fundamentally different from skill positions |
| db     | CB, S     | Coverage + ball production |
| lb     | LB        | Hybrid coverage + run defense |
| rb     | RB        | Rushing + receiving + athleticism |

**Why tiered and not fully separate:** Data sparsity. Positions like S (~180 total)
and TE (~150) don't have enough observations for standalone models with 15+
features. Groupings keep each sub-model at 300–600+ observations while respecting
fundamentally different evaluation criteria.

### Three-Way Model Comparison
| Model   | Role | Tuning |
|---------|------|--------|
| XGBoost | Tried-and-true tree baseline | `tune_race_anova()`, 50-point grid |
| TabPFN  | Foundation model for tabular data (zero-shot) | None — single forward pass |
| TabNet  | Attention-based deep learning with interpretability | `tune_grid()`, 30-point grid |

**Why three models:** XGBoost is the credible baseline. TabPFN (Nature-published
foundation model) tests whether a zero-tuning transformer beats tuned trees on
NFL data. TabNet provides attention maps showing what the model focuses on per
player. The comparison itself is high-quality content for both audience segments.

### Program Pipeline Features (Novel Differentiator)
- Rolling **10-year window** of program-by-position-group draft outcomes
- Leave-one-out computation to prevent leakage
- Features: hit rate, bust rate, volume, average AV, average draft position
  — all computed per program per position group
- **Rationale:** Coaching changes and scheme evolution matter. Saban's Alabama WR
  pipeline ≠ Shula's. This is the primary novel angle — most public models treat
  college program as a flat categorical.

### Features
- **Combine measurables:** 40, bench, vertical, broad jump, 3-cone, shuttle, ht, wt
- **Composite athleticism:** Position-relative z-scores (simplified RAS)
- **Draft context:** Pick, round, age at draft, years in college, underclassman flag
- **Program pipeline:** Position-specific and program-wide historical production
- **Conference strength:** Percentile rank of college's draft production

### Training Data
- Draft classes 2006–2020 (~3,750 players)
- 4-year AV window for outcome labeling (balances data volume against label quality)
- Combine measurables + college production + draft context + program pipeline

---

## Strategic Decisions Log

### R Over Python for Modeling
`nflreadr` and the nflverse ecosystem are R-first, significantly more mature than
any Python NFL data library. `tidymodels` provides clean workflow architecture
for the sub-model design. Python has no role in the 2026 draft model.

### Public GitHub — Transparency Is the Brand
Model code, outputs, and methodology are public. Accept that outputs are visible
before content publishes — the analysis and narrative layer is the value-add, not
the raw numbers.

### Why 4-Year AV Window
3-year is too noisy (many players don't stabilize). 5-year shrinks the training
set (can't use 2020 class). 4-year is the academic standard, aiding credibility.

---

## Content Strategy

### Voice & Persona
**Core identity:** The narrative-checker. "Here's what everyone is saying — now
let's look at what the data actually shows." Conversational and confident, like
a smart friend at the bar who happens to have a regression model on their laptop.
Contrarian takes are earned by the data, not manufactured for engagement.

See `CONTENT_GUIDE.md` for full voice guidelines, content templates, and
generation rules.

### Content Autonomy Levels
- **Player cards / data viz descriptions:** Claude generates autonomously
- **X posts:** Claude drafts, Merrittocracy heavily edits for voice
- **Substack posts:** Claude generates full first drafts, Merrittocracy edits

### Uncertainty in Predictions
Always show the range, never a point estimate. "Our model gives him a 35–55%
boom probability" — not "he has a 45% boom probability."

### Content Roadmap (5 Weeks to Draft)
- **Week 1:** Account setup + Substack origin post + GitHub repo public
- **Week 2:** Early model results on X + methodology Substack post
- **Week 3:** Combine data integration + position group deep dives
- **Week 4:** Full model-based mock draft with boom/bust probability ranges
- **Week 5 (Draft week):** Live X reactions + post-draft Substack grades

---

## Automation Architecture (Future Project — Not 2026 Draft)

Mac Mini M4 is on order. OpenClaw will not be running before the 2026 draft.
Do not design or build toward this architecture in the current project.

Planned for future content series (post-draft):
1. RSS feed monitoring → LLM summarization → draft insight summaries
2. X list monitoring → flag breaking news → model-informed reaction drafts
3. Scheduled data refresh → push updated outputs

Output flow and trigger patterns are open design decisions — revisit when the
Mac Mini arrives and OpenClaw is set up.

---

## Working With Claude

### Preferences
- Concise, direct responses — no fluff
- R over Python for modeling — Python has no role in the 2026 draft project
- Claude Code handles boilerplate; Merrittocracy handles domain judgment
- Public GitHub repo to build credibility with analytics community

### Ask vs. Assume
- **Architecture decisions** (new features, model changes, pipeline design): Ask first, pause for input
- **Implementation details** (column name fixes, package versions, code style,
  bug fixes): Make reasonable assumptions, note them, keep moving

### Disagreements With Documented Decisions
If you believe a locked-in decision should be revisited:
1. Flag the specific concern
2. Explain what evidence or circumstance changed
3. Pause for input — do not proceed with an alternative approach

### What Merrittocracy Handles
- Domain judgment (which narratives to challenge, which players to feature)
- Content voice and final editing
- Strategic decisions about brand direction
- OpenClaw/Mac Mini architecture (future project — keep completely separate)

### What Claude Handles
- Code implementation and debugging
- Data pipeline construction and maintenance
- Content draft generation (reviewed before publishing)
- Player card and data viz output generation (autonomous)
- Package/dependency management

### Do NOT
- Suggest switching to Python for the modeling pipeline
- Build any automation infrastructure for the 2026 draft project
- Over-engineer toward future OpenClaw/Mac Mini architecture — post-draft, separate project
- Add features without discussing data sparsity implications
- Merge position groups that have fundamentally different evaluation criteria
- Split position groups further without sample size analysis
- Silently change a locked-in decision — flag and pause instead
