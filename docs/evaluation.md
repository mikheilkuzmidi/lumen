# Evaluation

Fifteen CC0 photos from [Fixtures/photos](../Fixtures/photos), each with one instruction from [Fixtures/instructions.json](../Fixtures/instructions.json), run with `lumen eval` against the Meta Model API. These are single runs on one machine; models answer differently from run to run, so read them as observations, not benchmarks.

```sh
export META_API_KEY=…
swift build -c release --product lumen
.build/release/lumen eval Fixtures/instructions.json --out results
```

Each case writes the result, a before/after comparison, the full trace (every plan, critique, model call and time) and a row in `results/summary.md`.

## October 26, 2026, after the fixes (commit c4378f9)

Muse Spark (`muse-spark-1.3`) planned and checked, SAM 3.1 selected, Muse Image (`muse-image-1.0`) redrew. Up to 12 steps and 2 revisions per case; previews at 1536 px.

**The critic was satisfied with all 15 results, after one revision in total.** Judged by eye, 10 meet the instruction cleanly and 5 are weaker. 66 model calls in all; 285 s of wall time, a median of 17 s per case.

| Case | Instruction | Layers | Revisions | Critic | Calls | Time | Judged by eye |
| --- | --- | ---: | ---: | --- | ---: | ---: | --- |
| blue-vintage-car-on-a-dirt-road | Make the truck a deep cherry red and give the sky a warm late-afternoon glow. | 2 | 0 | Satisfied | 6 | 31.2 s | Met. Glossy cherry red, chrome and plate untouched; warm sky. |
| city-at-night | Bring out the city lights and cool the shadows a little. | 1 | 0 | Satisfied | 2 | 9.4 s | Met, subtly. |
| coffee-in-montreal | Make the nearer cup matte black and the room a touch warmer. | 2 | 0 | Satisfied | 5 | 35.6 s | Partly. The cup is redrawn in place and much darker, but dark teal rather than black. |
| colorful-asian-street-market | Make the red gate stand out more and calm the busy colours around it. | 2 | 0 | Satisfied | 8 | 18.9 s | Met. SAM found no "gate" by name; the planner's box found it. |
| dressed-in-red | Change her red sweater to a forest green knit. | 1 | 0 | Satisfied | 5 | 19.4 s | Met. A real knit texture; the printed lettering went with the old sweater. A faint red fringe along one sleeve. |
| hooded-woman-in-snow | Make the snow a cleaner white without changing her skin. | 3 | 1 | Satisfied | 5 | 32.7 s | Met. Skin unchanged; the fleece lining brightened with the snow. |
| man-in-black-jacket-on-street | Turn his black jacket into a tan suede jacket. | 1 | 0 | Satisfied | 5 | 16.8 s | Met. Convincing suede, folds kept; the back print is gone, as a plain suede jacket would be. |
| jacket-with-a-hood | Make his jacket bright yellow. | 1 | 0 | Satisfied | 5 | 29.8 s | Met. Mustard-leaning yellow; droplets, drawstrings and folds kept. |
| kayaks-on-a-mountain-lake | Make the sky more dramatic and the water a deeper turquoise. | 2 | 0 | Satisfied | 4 | 9.8 s | Met. Clean edges where sky meets cloud. |
| living-room | Replace the blue sofa with a green velvet one. | 1 | 0 | Satisfied | 5 | 17.1 s | Met. Velvet sheen, cushion and legs kept. |
| man-in-denim-jacket-posing | Make it feel like golden hour. | 1 | 0 | Satisfied | 2 | 9.1 s | Partly. A warm, even cast more than low golden light. |
| man-on-bike-on-road | Remove the no-cycling sign from the pole. | 1 | 0 | Satisfied | 4 | 16.4 s | Mostly. The sign is gone; a faint outline of its edge remains on the pole. |
| man-walks-in-front-of-graffiti-wall | Make the graffiti wall black and white and keep him in colour. | 1 | 0 | Satisfied | 3 | 12.1 s | Met. |
| stockholm-man-with-headphones | Brighten his face a little and make the crowd behind him less distracting. | 2 | 0 | Satisfied | 4 | 18.7 s | Weak. Both changes are too slight to see easily. |
| sunset-beach-couple | Make the sunset more vivid. | 1 | 0 | Satisfied | 3 | 7.7 s | Mostly. Vivid, but the boosted horizon forms a band right of the couple. |

Model time per stage across all 15 cases: plan 66 s, select 35 s, redraw 85 s (7 redraws, 8.4–18.3 s each), critique 97 s.

![The truck turned deep cherry red, with a warmer sky](images/eval/blue-vintage-car-on-a-dirt-road.jpg)

![The blue sofa replaced with green velvet](images/eval/living-room.jpg)

![The red gate stands out and the market behind it is calmer](images/eval/colorful-asian-street-market.jpg)

## What the first run found, and what changed

The first full run, earlier the same day, had the critic satisfied with 11 of 15, after 8 revisions. Looking at its results led to four changes, each verified by running the affected cases again.

| Problem in the first run | Cause | Change |
| --- | --- | --- |
| The redrawn cup came back small and shifted, then two revisions stacked new redraws on the broken pixels. | Muse Image got a 224 × 166 crop; a live probe showed the same crop upscaled to 1024 px kept the cup in place. | Small crops are upscaled before generating; SAM checks each redraw and a poor overlap gets one more try; a redraw replaces the run's earlier redraw of the same region ([#12](https://github.com/mikheilkuzmidi/lumen/issues/12)). |
| "Red gate", "gate" and "archway" all found nothing; the gate was never adjusted. | SAM 3.1 finds the gate's pillars and roof by name, but not the whole gate. A box prompt over it found the gate at 0.87. | When a name finds nothing, the planner's box or points become SAM's object prompt ([#13](https://github.com/mikheilkuzmidi/lumen/issues/13)). |
| The sky's adjustment met the clouds in blocky steps. | The mask's coarse edge was used as it was, feathered under 1 px. | Masks are fitted to the photo with a guided filter, and widened where the photo is smooth ([#13](https://github.com/mikheilkuzmidi/lumen/issues/13)). |
| The graffiti case ended on a revision's own finish, with a stale "needs revision" verdict. | A revision's finish was believed without a look. | A revision with a redraw or a failure is checked again ([#12](https://github.com/mikheilkuzmidi/lumen/issues/12)). |

![The cup in the first run: a small black cup and a smear where the old one was](images/eval/coffee-before-fixes.jpg)

![The cup after the fixes: redrawn in place](images/eval/coffee-in-montreal.jpg)

## October 27: what the maintainer's own photos found

Live runs on six of the maintainer's own photos (not in this repository) found four more problems. Each was fixed, and the same request was run again:

| Problem | Cause | Change |
| --- | --- | --- |
| "Bring out the city lights" made a night street darker. | Dehaze ran Core Image's contrast in linear light, where its 0.5 pivot is a light grey: every shadow went to black. | Dehaze works on sRGB-encoded values, and temperature moves in even mireds, so +35 warms about as much as −35 cools. The same request now brightens the street. |
| "A warm golden-hour glow" on a midday bridge came out bluer, then only warmer, and the critic accepted both. | There was no way to warm the highlights more than the shadows; vibrance made the blue sky bluer. | `highlightWarmth` and `shadowWarmth`; the planner is told what golden-hour light is, and the critic that only warmer isn't it. Now: gold highlights and a soft, warm sky. |
| Parked bicycles redrawn yellow had a smeared wheel and a smeared neighbour, and the critic called it clean. | The critic saw two 1024 px photos, where the smear was a few pixels. | Each region redrawn in a run goes to the critic close up, before and after. |
| Shirts redrawn blue on a black-and-white photo were saved grey, then had a dark band along their edges. | The export kept the photo's grey colour space; the redraw showed through SAM's mask grown past the shirt, where the generator drew a border. | A greyscale photo given colour is exported in sRGB; a recolour shows through SAM's mask fitted to the photo's own edges. |
## A whole library
`Fixtures/library` is a small CC0 shoot of 16 photos:

- people in T-shirts of several colours;
- a black-and-white photo and silhouettes;
- photos with nobody in them;
- a shaken frame and a pocket shot;
- two horizons tilted on purpose (+4° and −3°).
```sh
lumen batch Fixtures/library "Make everyone's T-shirts blue" --out results --mode autonomous
```

The last run on October 27 took 47 model calls and 393 s, and cost $0.43. Each part, judged by eye:

| Part | Result |
| --- | --- |
| Misfires | Both flagged (the shaken frame, the pocket shot) and left out. |
| Straightening | The lake (−3.6°), the street (+1.8°) and the grain elevators (+2.1°) levelled; the café, the city and the forest left alone. |
| Questions | Whether to straighten, answered in autonomous mode with the recommendation; in other runs, the shirt style, the black-and-white photo, partly hidden people, the shade of blue. |
| Shirts | Four photos planned and recoloured: all four T-shirts on the hilltop, both in the forest, the three women's tops by the grain elevators, and the boys' shirts in the black-and-white photo. That photo was exported grey, which led to the last change below. |

Lumen Studio's Library (plan-first, 37 calls) and Photoeditor's prompt bar (plan-first, 34 calls) ran the same library with the same agent.

Each of these runs found something, and each was fixed and run again:

| Problem found live | Change |
| --- | --- |
| Auto darkened high-key photos by a full stop and stretched whites and blacks on almost every photo. | A gentle Auto: exposure moves only outside 0.35–0.6 median lightness, at most 0.7 stop. |
| Core Image found no tilt in either tilted photo; Vision then read perspective lines in a café and a forest as tilt. | Vision measures; the reviewer says whether the camera was visibly tilted; at most 6°. |
| A white T-shirt stayed white: SAM didn't find it by name, so its neighbour's blue shirt was selected each time. | The planner's point or box decides which segment is meant; otherwise they become SAM's own prompt. |
| A recoloured shirt was checked for its old colour, called "moved" and redrawn again. | The redraw check searches without colour words, and a match outside the region counts as no check. |
| The reviewer matched only one shirt photo to the instruction, so nothing was recoloured. | Every photo goes to Muse Wonder with the reviewer's impression as a hint; the planner decides. |
| "Blue with the same subtle pattern" left a pale patterned shirt as it was. | Colour changes are asked for from what to what. |
| After the portrait rule below, the reviewer called the tilted lake and street level: an October 27 run left both crooked. A rule that water is always level fixed three review-only runs, but not a run with an instruction. | The reviewer also names the line that should be level: horizon, water, building or none. A contact sheet shows that plainly where a 3° tilt is hard to see. A measured tilt with a horizon or water line is straightened; with none, it is not. |
| Muse Wonder planned the T-shirts on one photo of four. It decided from the reviewer's few-word descriptions, which left the shirts out. | Photos the reviewer matched from the image stay in unless their description rules the instruction out. |
| The boys' shirts in the black-and-white photo were redrawn blue but exported grey: the export kept the source's grey colour space. | A greyscale photo that an edit gives colour is exported in sRGB. |
## At scale

The project's 126 local test photos cover portraits, faces, groups, pets, landscapes, cities, water, snow, night, indoor flash and studio. They are the maintainer's own test set, so they are not in the repository, and only the numbers are reported here.

| Run | What it did | Time | Calls | Cost |
| --- | --- | --- | --- | --- |
| Base pass, autonomous, before the reviewer fix | Reviewed all 126; flagged 6; levelled 12; 9 closer looks | 120.5 s | 28 | $0.47 |
| Review and straightening only, after the fix (commit 0022e59) | Reviewed all 126; flagged none; levelled 6 landscapes, harbours and water scenes | 63.1 s | 7 | $0.21 |

The first run flagged six good photos as "badly blurred": a baby's portrait, a child in soft light, a family on a sofa, storm clouds, a beagle and sleeping puppies. Their soft backgrounds and soft light had lowered the whole-frame sharpness that the reviewer is shown. It also levelled portraits by up to 5.7°.

The reviewer is now told three things:

- low sharpness alone is never a misfire;
- verticals that lean in a shot taken upward are perspective, not tilt;
- a portrait counts as tilted only when a horizon or building edge behind the person is clearly off.

Automatic straightening also stops at 5°. In the second run none of the six was flagged and no portrait was rotated. It also left one genuinely tilted harbour view alone, so it errs on the side of not straightening.

At the second run's rate, reviewing 1,000 photos takes about 8 minutes and about $1.70. Edits that redraw something come on top, at about 5 calls per photo.
## Follow-ups and undo

A gated live test (`LUMEN_LIVE=1 swift test --filter followsUpOnTheSameEdit`) runs three instructions on one photo. On October 26 it took 49 s:

1. "Make his jacket bright yellow": select, redraw, satisfied.
2. "A bit less yellow": no new selection; saturation −25 on the remembered jacket.
3. "Undo that": reverts only that adjustment and ends without a critique.

The first run of this test found the critic asking to undo the earlier redraw too, because it did not know what "that" referred to. The critic now gets the earlier instructions.

The same three instructions pass in Photoeditor's prompt bar through its scripted QA (a private repository).

## Open weights

Muse Glimmer on this Mac completed the jacket instruction in about 4.5 minutes, against 27 s with Muse Spark; see [open-weights.md](open-weights.md). Muse Spark Open has not been run: no hosting credits were used.

## Limits of this evaluation

- One run per case. A second run of the same case can plan differently.
- The instructions were written for these photos and these models.
- Judgments by eye are one person's.
- The critic is the same model as the planner, so "Satisfied" is the system's own verdict; the column beside it is the independent one.
