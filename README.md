# Agnomen

Rename the files in a folder after what is actually *inside* them.

Agnomen reads each file on your Mac (text, PDFs, scans, screenshots and photos, Office documents, audio/video
metadata), asks Apple's on-device language model what the file is about, and proposes a descriptive name. You
review and edit every proposal in a preview before anything changes, and every batch can be undone.

*agnomen (Latin): an extra name given to someone for a distinguishing trait.*

| Before | After |
|---|---|
| `IMG_4021.png` | `Boarding Pass Delhi to Mumbai December 2025.png` |
| `scan0042.pdf` | `Lab Report Acetic Acid Titration 0.83 M.pdf` |
| `Book1.xlsx` | `Spreadsheet Household Budget 2025.xlsx` |

## Privacy: three models, you choose

| Mode | Where your files' text goes |
|---|---|
| **On-device only** (default) | Nowhere. Runs on Apple's on-device model. The shipped app is App Sandboxed with **no network entitlement**, so macOS itself blocks it from going online (`Agnomen --net-probe <port>` demonstrates this against a loopback server). |
| **Private Cloud Compute only** | The text Agnomen extracts from each file (up to ~6,000 characters, including OCR text) is sent to Apple's Private Cloud Compute. Needs a one-time consent. |
| **Both: compare side by side** | Both models answer for every file; each row shows both names and you click the one you want. |

The cloud modes are opt-in and the footer always says whether text is leaving your Mac.

> **Status of cloud modes:** on the macOS 27.3 seed this was developed on, the Private Cloud Compute API reports
> *available* and returns its 32k-token context size, but actual generation requests fail with a system error.
> The app handles that gracefully (friendly message, and it stops retrying after three consecutive failures),
> but cloud generation itself is **unverified**. On-device mode is fully tested.

## Features

- **Reads what's inside**: plain text/code/CSV/JSON/HTML, PDFs (text layer, then OCR for scans), images (Vision OCR
  plus on-device scene classification), Word/PowerPoint/Excel (own ZIP+XML reader, no dependencies), RTF,
  audio/video metadata. iCloud files that aren't downloaded are skipped, since opening them would use the network.
- **Preview first**: editable names, per-row checkboxes, type a name yourself for anything the model couldn't read.
- **Naming styles**: Title Case, kebab-case, snake_case, switched instantly without re-running the model.
- **Name templates**: `{title}`, `{date}`, `{created}`, `{year}`, `{original}`, e.g. `{date} {title}` or
  `{title} ({original})`, or your own pattern.
- **Hints**: tell it "these are tax documents"; optionally hide the old file name from the model.
- **Safe renaming**: never overwrites; a name that gets taken after analysis is refused; collisions get ` 2`, ` 3`;
  file extensions are never changed.
- **Undo**: every batch is journaled and can be undone, including after a relaunch.
- **Finder comment** (optional): store the one-line description in the file's Finder comment so Spotlight can
  find it by meaning. Undo removes exactly what it wrote.
- **CSV export** of the plan.
- **Fast**: the next files are read (OCR/parsing) while the model works on the current one.

## Install

Requires an Apple Silicon Mac on macOS 27 with Apple Intelligence turned on.

```sh
brew tap aakarsh-goyal/agnomen https://github.com/aakarsh-goyal/agnomen
brew install --cask agnomen
```

The cask installs Agnomen.app into /Applications (a prebuilt, ad-hoc-signed build) and clears the download
quarantine flag so it launches. Or build it yourself:

```sh
git clone https://github.com/aakarsh-goyal/agnomen.git && cd agnomen
Scripts/build.sh --install     # builds, signs with the sandbox entitlements, installs, launches
```

Drop a folder on the window, on the Dock icon, or use **Open With → Agnomen** on a folder in Finder.

## Performance

Measured on an M5 MacBook Air (16 GB) over a real folder of 67 screenshots, on-device model:

| Strategy | Wall time |
|---|---|
| One file at a time | 82.7 s |
| Read everything first (all cores), then run the model | 83–84 s |
| **Pipelined: read ahead while the model works (shipped, 4 files in flight)** | **76–79 s** |
| Pipelined, 16 or 32 files in flight | 76 s / 79 s |

Reading a file (OCR, parsing) averages ~110 ms; the model averages ~1.1 s, so the model is the bottleneck.
Reading everything first costs the whole read phase (~6 s) on top of the model's ~77 s. Pipelining hides it, and the
model's speed is the same either way (77 s model-only vs 76–79 s pipelined), so OCR running alongside doesn't
slow it down measurably. Going wider than ~4 files in flight gains nothing; the model is the limit, not the
scheduler. (A first, cold run after the model had been paged out took ~130 s once; warm runs don't.)

## Diagnostics

The binary doubles as a test harness (`Agnomen.app/Contents/MacOS/Agnomen`):

```
--dry-run <folder> [--mode onDevice|cloud|both] [--style …] [--template "{date} {title}"] [--no-name] [--hint "…"]
--extract <file>        show exactly what text the model would be given
--selftest              unit checks: naming, templates, collisions
--rename-test <folder>  real apply → verify → undo round trip on a scratch folder
--net-probe <port>      prove whether the sandbox blocks networking
--pcc-probe             Private Cloud Compute availability/quota and one tiny synthetic call
--render-preview out.png [folder] [--live] [--dark] [--demo-both]
```

## Uninstall

```sh
brew uninstall --cask agnomen          # the app
brew uninstall --cask --zap agnomen    # ...and its history and preferences
```

## License

MIT
