---
name: visual-artifacts
description: Creates a polished local HTML page when an explanation, a comparison or a small dashboard is better seen and tried. Also use it on an explicit request for a local visual; a short answer, an office document or an application to deploy is not enough to trigger it.
---

# Visual artifacts

Produce an HTML file the user can open, understand and keep in their project. Match the care to the subject: a utility page deserves a precise composition, without becoming a poster. This skill is self-contained and needs no account, remote service or other skill.

## Choose the direction

Respect, in this order, the user's choices, the style already present in the project, then the decisions made here. Read the project's relevant instructions and styles before inventing a theme.

Define the concrete subject, the audience and the single task of the page. For an explanation, make a relation or a sequence understandable; for a comparison, place the same criteria on the same axes; for a dashboard, show the situation and the useful action before the details. Keep a detail specific to the subject in the content: units, real steps, vocabulary or scales. Use the data provided; failing that, clearly announce fictitious data. Do not fill with placeholder text nor present an estimate as a measurement.

Before the code, announce a small visual plan:

- A palette of four to six named colours with their hexadecimal values: background, surface, text, secondary text and accent; add the state colours if they make sense.
- The typographic roles: headings, reading and figures if needed, with locally available fonts and fallback families. Distinct weights and sizes can be enough; choose two families only if their pairing serves the subject.
- The layout in one or two sentences: reading order, place of the useful control and adaptation to a narrow width.

A sober direction is the default choice. For an expressive request, concentrate the character on one choice relevant to the subject and keep the rest calm. Avoid automatic recipes: huge introduction, purple and blue gradient, systematic cream and terracotta, section emojis, everything centred, shadow and rounded corners on every block. An explicit choice of the user still comes first.

## Compose the page

- **Hierarchy.** Give a short and specific name to the `<title>` and to the visible heading. Make the essentials readable on load, with no introduction screen taking the full height. A tool opens with a credible example already visible, not an empty shell. Keep large figures for the values that really are the subject.
- **Typography.** Use a consistent size scale, comfortable line heights and paragraphs about 65 characters wide. Balance long headings; give small labels some air. Align comparable values with `font-variant-numeric: tabular-nums`.
- **Colours.** Choose the neutrals as carefully as the accent. Define colours in CSS variables, with an explicit background on `body` and a readable contrast. States also use an understandable word or symbol, never colour alone.
- **Theme.** A single explicit theme is enough by default; declare its `color-scheme` and all its colours, controls included. If a system theme or several themes are requested, define a complete palette per theme; the user's explicit preference wins over the system's. Check each theme delivered. Do not add a switcher for demonstration only.
- **Layout.** Use flex or grid and `gap` for groups. Repeated elements share edges, alignments, spacing and control positions. Let the content set the height. A border, a background, a radius or a shadow must express a useful grouping; do not turn every piece of information into a card.
- **Narrow width.** Let texts and columns wrap. A really wide table or code scrolls in its own container; the whole document must not overflow horizontally. Keep the useful labels and avoid truncated texts.
- **Charts.** Use the same scale for values, marks and ticks; show units and labels without collision. For a simple SVG, reserve the labels' space in the `viewBox` and set fills explicitly. A CSS bar or a small SVG is often enough; keep the data readable as text. Add a chart only if it explains better than the figures alone.
- **Interactions.** Use semantic HTML elements: buttons, fields and native controls with labels. Make the action visible, the keyboard focus sharp and the result understandable, including when a filter finds nothing. Tell a filtered state apart from overall totals. Headings and numbers express the structure of the content; number only a real sequence.
- **Text.** Name things as the user recognises them. Controls say what they do; errors say what is missing and how to move on. Keep implementation details out of the path.

## Build for local use

For simple uses, write a single HTML file with its CSS, its data and the useful JavaScript embedded. No framework, package install, build or server is needed. Use the local resources already allowed or embed them; do not load any font, script, image or stylesheet from a CDN. Plan typographic fallbacks and deliver any essential local file with the HTML if a single file does not fit.

Interactions work in the browser on the page's data: filter, sort, choice or simple computation. Do not use hosting APIs such as `window.claude`, connected data or a backend. If the request requires a service or a persistent application, explain the limit and clarify the widening before changing solution. Do not promise that a change will be kept at the next opening if nothing saves it.

Keep all content to be read visible at rest; no reveal depending on scrolling and no decorative animation by default. If motion explicitly serves the task, respect `prefers-reduced-motion`. Take care of the CSS cascade, closed tags and attributes in double quotes.

## See and hand over the result

Keep the HTML at the requested location or in a clearly named project folder. Check that it does not overwrite a foreign file; choose another name on collision. Do not publish nor share the page.

Open the file with the available browser tool. Do a useful inspection: overview, width reduced to 375 px, reading of texts and charts, then a try of the control with mouse and keyboard. Check only the themes implemented and the absence of a needed external resource. Fix the defects observed with the smallest justified change, then replay only the check concerned. Do not create a campaign of tests or screenshots to judge your own style.

Provide a clickable local link to the kept HTML and one sentence on what the page lets the user see or try. If automated opening is unavailable, still deliver the file, stating exactly which checks were not done; do not claim a rendering or an interaction that was not tried.
