# Merrittocracy — Content Guide

## Voice & Persona

**Core identity:** The narrative-checker. Merrittocracy's angle is: "Here's what
everyone is saying — now let's look at what the data actually shows."

**Tone:** Conversational and confident, like a smart friend at the bar who happens
to have a regression model on their laptop. Not academic, not hot-take-for-the-
sake-of-it. The contrarian takes are earned by the data, not manufactured for
engagement.

**What this sounds like:**
- "The consensus has Cam Ward as QB1. Our model agrees — but not for the reasons
  you'd think. His arm talent matters less than where he played."
- "Everyone's calling this edge class 'historically deep.' Let's check the
  receipts."
- "Ohio State keeps producing first-round WRs who hit. Their QBs? Different
  story. Here's why the program pipeline matters."

**What this does NOT sound like:**
- Academic: "Our regression analysis with p < 0.05 indicates..."
- Hot take: "This guy is a GUARANTEED BUST and I don't care what anyone says"
- Hedged to death: "It's possible that perhaps in some scenarios..."
- Generic AI: "In this article, we'll explore the fascinating world of..."

**Key principles:**
1. Lead with the narrative challenge, not the methodology
2. Show confidence in the model's output, but always show the range
3. Make the data accessible — anyone should understand the conclusion, analytics
   people can dig into the method
4. Credit uncertainty honestly — "our model gives him a 35–55% boom probability"
   not "he will boom"
5. The methodology IS content for the analytics audience — don't hide it, just
   don't lead with it for general audiences

---

## Content Types & Autonomy Levels

### Player Cards / Data Viz Descriptions — AUTONOMOUS
Claude can generate these without review. They're templated outputs from model
results.

**Player card format:**
```
[Player Name] | [Position] | [School]
Boom probability: [X–Y%]
Bust probability: [X–Y%]
Model verdict: [BOOM / BUST RISK / Upside / Caution / Baseline]

Program pipeline: [School] has produced [N] drafted [position group] in the
last 10 years with a [X%] boom rate.

Athletic profile: [Elite / Above-average / Average / Below-average / Limited]

Key signal: [One sentence on what drives the model's prediction]
```

### X Posts — DRAFTED FOR REVIEW
Claude generates drafts; Merrittocracy heavily edits for voice before publishing.

**X post guidelines:**
- Max 280 characters for standalone posts; threads can go longer
- Lead with the contrarian or surprising finding
- One data point per post — don't overload
- Use "our model" not "the model" or "my model" — it's a brand voice
- End threads with a link to the Substack deep dive when available
- Data viz images should be self-explanatory without the tweet text

**Thread structure (for deep-dive threads):**
1. Hook: the narrative being challenged
2. The data point that challenges it
3. Context: why the conventional wisdom exists
4. What the model sees differently (1-2 tweets)
5. The takeaway
6. Link to Substack for full methodology

**Example drafts Claude might produce:**

Good: "Everyone's mocking [Player] in the top 10. Our model sees a 40–52% bust
probability at that range. The program pipeline is the red flag — [School] has
produced 6 drafted [position group] since 2015. Boom rate? 17%."

Bad: "Our XGBoost model trained on 15 years of draft data using tidymodels with
10-fold stratified cross-validation indicates that [Player] has elevated bust
risk." (Too technical for X, leads with methodology instead of insight)

### Substack Posts — FULL DRAFTS FOR REVIEW
Claude generates complete first drafts; Merrittocracy edits for voice and
narrative emphasis.

**Substack structure:**
- **Title:** Specific and intriguing, not generic. "Ohio State's WR Factory vs.
  Their QB Graveyard" not "Analyzing College Program Draft Outcomes"
- **Opening:** The narrative being examined (1–2 paragraphs)
- **The data:** What the model shows, with inline visualizations
- **The analysis:** What it means, why the data might diverge from consensus
- **Methodology note:** Brief section at the end for analytics readers — link to
  GitHub for full code
- Target length: 1,000–2,000 words for analysis posts, 2,000–3,000 for
  methodology deep dives

**Substack post types:**
1. **Methodology posts** — how the model works, what makes it different
   (audience: analytics community)
2. **Position group deep dives** — QB class analysis, WR class, etc.
   (audience: both)
3. **Narrative-checking posts** — "everyone says X, the data says Y"
   (audience: primarily NFL fans, shared on X)
4. **Model results** — full mock draft, post-draft grades
   (audience: both)

---

## Handling Model Uncertainty in Content

**Always show the range, never a point estimate.**

- Write: "Our model gives him a 35–55% boom probability"
- Don't write: "Our model says he has a 45% boom probability"
- Don't write: "He will boom" or "He's a bust"

**When the model is uncertain (probabilities clustered near 33/33/33):**
- Be honest: "The model doesn't have a strong read here — he's close to
  baseline across the board"
- Use it as content: "This is the hardest player in the class to evaluate,
  and the model agrees"

**When the model disagrees with consensus:**
- Lead with it — this is the brand's core value proposition
- Show the specific features driving the disagreement
- Acknowledge what the consensus sees that the model might miss
  (scouting context the model doesn't capture)

**When the model agrees with consensus:**
- Still valuable — "The consensus is right, and here's the data that
  backs it up"
- Look for nuance: "Everyone agrees he's good, but our model says it's
  his program pipeline driving the signal, not his combine numbers"

---

## Formatting & Style

**Numbers:**
- Percentages: "35–55%" not "35% to 55%" (use en-dash for ranges)
- AV: always define on first use in any piece, then use freely
- Round probabilities to nearest whole percent in X posts, one decimal
  in Substack

**Terminology:**
- "Our model" — brand voice, first person plural
- "Boom probability" / "bust probability" — always lowercase, always with
  "probability" (not "boom score" or "bust rating")
- "Program pipeline" — the branded term for the college-by-position-group
  feature. Use consistently.
- "Narrative-checking" — what Merrittocracy does. Not "myth-busting" (too
  aggressive) or "fact-checking" (political connotation).

**Attribution:**
- Always credit data sources: "Data via nflverse/nflreadr" or
  "Data: Pro Football Reference"
- Link to GitHub repo when discussing methodology
- Link to Substack when sharing findings on X

---

## What Claude Should NEVER Generate as Content
- Definitive predictions without probability ranges
- Content that disparages specific teams, coaches, or programs without data
  backing
- Anything that could be mistaken for betting advice
- Content using Merrittocracy's voice that hasn't been flagged as a draft
- Hot takes for engagement that aren't supported by the model
- Claims about a player's character, work ethic, or intangibles — the model
  sees measurables and production, not people
