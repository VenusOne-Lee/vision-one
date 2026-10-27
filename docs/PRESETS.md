# Prompt presets

Every template part (hook, title, body, outro, captions, zooms, B-roll, music, sound effects, thumbnail, title + post, chapters, clips) has its own prompt. A preset is a named set of your own versions of those prompts, plus a house style above them all. Research and mockups: [iPhone and Prompt Presets](https://claude.ai/artifact/MEn3osXANGbz89GksBwoE1).

## The file

One Markdown file per preset in `~/Library/Application Support/Vision One/Presets`. Headings name the parts (`PromptSlot`), the same ones a template's `prompts.md` uses. Parts a preset leaves out use the template's default. Unknown headings are kept when saving.

```md
---
name: Mzansi warm
energy: lively
---

## House style
Talk like a South African builder explaining to a friend. Plain words,
short sentences, rand not dollars. Name {product} early and end on {cta}.

## Hook
Open on the problem {audience} feels, in under 3 seconds. No "hey guys".
```

Vision One ships three: Straight talk, Mzansi warm and Launch hype. Saving a built-in one writes your own copy, which then replaces it in the list.

## How a prompt is put together

`PromptResolver.resolve(slot:template:preset:moment:variables:)` picks the most specific prompt for a part:

1. what you asked for this moment (ask bar, a word, a frame),
2. the preset's prompt for that part,
3. the template's default.

The preset's house style (or the template's) goes in `system`, the winning prompt in `instruction`, so agents can put house style on the instructions side and the transcript on the input side. `{product} {audience} {site} {cta} {ring}` are filled from `PromptVariables` (the Version One listing or brand kit); unknown ones stay visible and are listed in `missingVariables`. `PromptSlot.agentKey` gives the key the agents' `AgentBrief` uses.

| Type | What |
| --- | --- |
| `PromptSlot` | The parts, their headings, and the agents' keys |
| `PromptDocument` | Reads and writes front matter + `## Heading` Markdown |
| `PromptPreset` | A preset, its file name, and the built-ins |
| `PresetLibrary` | Loads, saves and deletes your presets |
| `PromptResolver`, `PromptVariables` | Puts the final prompt together |

Not yet: the presets sheet in the app (needs templates and agents to land).
