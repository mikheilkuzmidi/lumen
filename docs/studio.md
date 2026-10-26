# Lumen Studio

Lumen Studio requires macOS 26 and Xcode 26. Build the app from the repository root:

```sh
scripts/build-studio.sh
open ".build/studio/Lumen Studio.app"
```

The build script makes a release build, adds the app icon and signs the bundle locally. Pass a destination folder as its first argument to put the app elsewhere. Set `SIGN_IDENTITY` to sign with your own identity.

If macOS blocks an unnotarized build, try opening it once, then go to **System Settings › Privacy & Security › Open Anyway**. For a build you trust, you can instead remove its quarantine attribute:

```sh
xattr -dr com.apple.quarantine ".build/studio/Lumen Studio.app"
```

Open Settings with the gear button and paste your Meta API key. Studio stores it in this Mac's Keychain under service `Lumen`, account `meta-api-key`. If no key is saved, Studio reads `META_API_KEY` from its environment. A Finder launch does not inherit variables from your terminal, so use Settings or launch the executable from that terminal.

The header shows the photo's name and pixel size, plus Open, Settings and Export. The canvas fits the photo with space around it; use the Fit and zoom controls below it to inspect details. Drag a box on the photo to tell Lumen where to look, then move it or resize its corners. Escape clears the box. Compare shows the original; holding Space also compares when you are not typing.

The instruction field below the canvas sends your request with Run. Stop cancels the edit. The backend menu currently uses Meta: Muse Spark plans and checks, SAM 3.1 selects regions, and Muse Image redraws them. Selection masks reveal on the canvas while the edit runs.

The Steps tab on the right follows the current step and scrolls through longer plans. Expand Details for model timings and trace text. Hover truncated labels to read them in full. The Layers tab shows each applied change, newest first, with visibility and opacity controls. Undo and Redo restore layer changes. Export writes the full-size edited JPEG or PNG; the original stays untouched.

## Scripted runs

Run the executable directly to capture Studio without changing screen focus:

```sh
".build/studio/Lumen Studio.app/Contents/MacOS/LumenStudio" \
  --script edit.json --out /tmp/lumen-studio
```

The script uses the same edit code as Run and makes real requests with your Meta key. Building and testing do not require a key or make paid requests.

```json
{
  "photo": "photos/jacket.jpg",
  "area": {"x": 0.2, "y": 0.1, "width": 0.4, "height": 0.7},
  "instruction": "Make the jacket bright yellow, keeping its shape and folds",
  "backend": "meta",
  "window": {"width": 1440, "height": 900}
}
```

Photo paths can be absolute, start with `~`, or be relative to the script file. Set `area` to `null` or omit it to use the whole photo. Area coordinates are fractions from the photo's top-left corner and must stay inside it. Window dimensions are in points, at least 980 × 680 and at most 8192 × 8192.

Scripted mode starts as an accessory application and creates a nonactivating, mouse-ignoring window beyond the visible screens. It captures the window content at its backing scale without screen recording. Keychain access cannot display an authentication prompt in this mode; unlock or authorize the saved key in the interactive app first if needed.

The output folder contains the first occurrence of each milestone:

| File | Window content |
| --- | --- |
| `1-opened.png` | Photo loaded |
| `2-area.png` | Area box, when supplied |
| `3-planned.png` | Plan in the Steps tab |
| `4-selected.png` | Selection mask about 0.6 seconds into its reveal |
| `5-redrawn.png` | First patch layer applied |
| `6-finished.png` | Finished edit |
| `7-compare.png` | Original shown with Compare |
| `8-layers.png` | Edited photo with the Layers tab open |

Selection and redraw snapshots are omitted when the plan never reaches those events. The run also writes the full-size `result.jpg` and a readable `timeline.txt`, then exits. Failures write `error.txt` and exit with a nonzero status. Reusing an output folder replaces these known output files; use a separate folder for each run to keep earlier captures.
