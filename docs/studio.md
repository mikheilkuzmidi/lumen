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

The instruction field below the canvas sends your request with Run. Stop cancels the edit. Selection masks reveal on the canvas while the edit runs.

The Steps tab on the right follows the current step and scrolls through longer plans. Expand Details for model timings and trace text. Hover truncated labels to read them in full. The Layers tab shows each applied change, newest first, with visibility and opacity controls. Undo and Redo restore layer changes. Export writes the full-size edited JPEG or PNG; the original stays untouched.

## Choose the planner

Use the menu above the instruction field to choose who plans and checks. Studio remembers your choice. All three choices still use SAM 3.1 and Muse Image through the Meta API for selection and redrawing, so you still need your Meta key.

- **Muse Spark (Meta)** is the default. It plans and checks through the Meta API with your Meta key.
- **Muse Glimmer on this Mac** plans and checks locally. Install `llama-server` with `brew install llama.cpp`, then run `scripts/get-glimmer.sh` to fetch both the model and vision projector. Studio checks the same executable paths and model files as the command line. If something is missing, the choice is disabled and its help names the missing requirement and remedy.
- **Muse Spark Open** plans and checks on your hosting provider. In Settings, enter the deployment's base URL, API key and model ID, then click **Save Provider**. Include `/v1` in the URL when your provider requires it; Lumen appends `/chat/completions`. The default model ID is `meta-models/muse-spark-open-1026`; use your deployment's ID if different. The URL and model ID are saved in settings. The key is kept in the Keychain under service `Lumen`, account `spark-open-api-key`, separately from the Meta key. The menu enables this choice once the saved provider settings are usable. Saving settings makes no model request.

Choosing Glimmer loads it in the background. The window shows **Loading Muse Glimmer on this Mac…**, then the measured load time. You can submit an instruction during loading; it waits for the model. If loading fails, Studio shows the error's message and returns the choice to Muse Spark. Switching planners stops a server Studio started; switching during an edit also stops that edit. Closing the window or quitting also stops Studio's server.

An already-running server at `LUMEN_GLIMMER_URL`, or `http://127.0.0.1:8786/v1` by default, enables the choice even without local model files. Studio reuses that server and never stops it. Otherwise it starts its own local server on that URL's port. Model files default to `~/Library/Application Support/Lumen/Models/muse-glimmer/`; set `LUMEN_GLIMMER_DIR` to use another directory. Environment variables must be present when launching Studio, as with `META_API_KEY`. See [open weights](open-weights.md) for file names, sizes and installation details.

On October 26, 2026, an M4 Max with 36 GB unified memory took about **33 seconds to load Glimmer** and **70–90 seconds per plan or check**. These are single runs with other applications open, not benchmarks. The planning row warns that a plan may take a minute or more on this Mac. Steps show **Muse Glimmer** and the actual call durations, separately from loading time. The complete measured edit took about 4.5 minutes; Muse Spark remains the default.

## Scripted runs

Run the executable directly to capture Studio without changing screen focus:

```sh
".build/studio/Lumen Studio.app/Contents/MacOS/LumenStudio" \
  --script edit.json --out /tmp/lumen-studio
```

The script uses the same edit code as Run. Set `backend` to `meta`, `glimmer` or `spark-open`; it uses that planner for this run without changing your remembered menu choice. Glimmer reuses an answering server or loads the installed model, waits before planning, and stops only a server Studio started when the run ends or fails. Spark Open uses the provider saved in Settings. Selection and redrawing make real requests with your Meta key for every backend. Building and testing do not require a key or make paid requests.

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
