# Audio replay tool

`build/audio-replay` replays your own recordings through Deepgram or AssemblyAI
under named settings ("variants") and scores each transcript against a reference
you typed. Use it to decide whether a change, such as a different sample rate,
resampler, `endpointing` value, keyterm budget, isolation strength, gain or
speech provider, makes transcripts better or worse.

Some things to know first:

- It is a developer tool and is never part of the app. `make` builds the app
  from `Sources/` only. This folder is compiled only by `make audio-replay`.
- Only you run it, with your own Deepgram or AssemblyAI key and your own
  recordings. It never opens the microphone.
- Audio leaves your Mac only after the tool has shown the estimated cost and you
  have confirmed. It goes only to the providers your variants name: Deepgram,
  unless a variant sets `provider=assemblyai` (section 4).

## 1. Build

Run these from the repo root:

```bash
make audio-replay          # writes build/audio-replay
REPLAY="$PWD/build/audio-replay"
"$REPLAY" --help
```

`REPLAY` holds the tool's full path, so every `"$REPLAY"` command below works
from any folder, including the lab folder of section 3, where the later
sections run. A variable lasts only as long as its terminal window. In a new
window, set it again with the full path from any folder, for example
`REPLAY=~/freeflow/build/audio-replay` when the repo is in `~/freeflow`
(change the path if your clone lives elsewhere).

`make check` type-checks this folder through the `typecheck-tools` target so it
cannot rot. It never runs the tool and never touches the network. The scoring
logic in `ReplayEvalCore.swift` is unit-tested by `Tests/ReplayEvalCoreTests.swift`.

## 2. Compare files offline with `stats` (no key, nothing sent)

Set up the lab folder from section 3 first and put the files to compare in it.
Copy a recording out of Downloads, Desktop or Documents with Finder: reading
those folders from Terminal can trigger a folder-access prompt.

```bash
"$REPLAY" stats "$HOME/FreeFlowAudioLab/wispr-recording.m4a" "$HOME/FreeFlowAudioLab/clip01.wav"
```

Each file gets a block like this:

```text
[1] clip01.wav
    format: 16000 Hz, mono, lpcm 16-bit, 4.21 s
    peak: -7.3 dBFS
    speech RMS: -27.9 dBFS (active 64% of the file)
    energy above 4 / 7 / 8 kHz: 3.10% / 0.40% / 0.00%
```

How to read it:

- **Format**: the sample rate decides the highest frequency a file can hold,
  which is half the rate. A 16 kHz file can hold nothing above 8 kHz, so it
  always shows 0% above 8 kHz. That is by design, not a fault. A 44.1 or 48 kHz
  file with real energy above 8 kHz sounds brighter for that reason alone. For a
  stereo file, only channel 1 is analysed, which is also the channel the
  replays use.
- **Peak** is the loudest sample. 0 dBFS is digital full scale, so a peak near
  0 may be clipped.
- **Speech RMS** is the average level over the 50 ms frames louder than
  -50 dBFS, which are roughly the frames with speech. If the FreeFlow file is
  much quieter than the Wispr file (say 10 dB or more), check the input volume
  in System Settings > Sound > Input before blaming the pipeline.
- **Energy above 4 / 7 / 8 kHz** is the share of the speech energy above each
  frequency. The "s", "f" and "th" sounds live in the 4 to 8 kHz region.

## 3. Set up a lab folder

Keep recordings and results in a private folder outside every git repository.
Avoid Desktop, Documents and Downloads, which can trigger folder-access prompts.
Create the folder and run the commands of this section from inside it:

```bash
mkdir -p ~/FreeFlowAudioLab && chmod 700 ~/FreeFlowAudioLab
cd ~/FreeFlowAudioLab
```

Copy some Run Log recordings in. The development build keeps them in the
folder below; the release build uses `FreeFlow` instead of `FreeFlow Dev`.
Always quote the path, because it contains spaces:

```bash
ls -lt "$HOME/Library/Application Support/FreeFlow Dev/audio/" | head -20
cp "$HOME/Library/Application Support/FreeFlow Dev/audio/<file name>.wav" clip01.wav
```

For each clip, listen to it and type what you said into a matching `.txt`
file, for example `clip01.txt`. Write it the way Deepgram's `smart_format`
(on by default) prints text, not the way it sounds: digits and symbols for
numbers, times, money, emails and URLs, such as `6:30`, `4471`, `$18,500`,
`12%`, `priya@example.com` and `docs.example.com/replay/setup`. Punctuation
and case are irrelevant to the main WER, which ignores them, but the scorer
never turns number words into digits: "six thirty" in the reference and
"6:30" in the transcript count as errors in every run.

Paired deltas between variants stay fair even so, because every variant is
scored against the same reference and pays the same fixed errors (except a
`smart_format=false` variant, which a spoken-form reference flatters).
Absolute WER needs written-form references. The `formatted_wer` column in
`results.csv` also counts case and punctuation. When you are unsure how
Deepgram writes something, do a first small run with `--save-transcripts`,
then fix only how such items are written in your reference, never which
words you said.

[`lab-script.txt`](lab-script.txt) gives every line twice: `SAY:` is what
you read aloud (skip the instructions in parentheses), and `REF:` is the
same line in written form. A take's reference file holds the `REF:` text of
the lines read in that take, in order, without the `REF:` labels and the
line numbers.

Then list the pairs in `manifest.tsv`. Columns are separated by a tab, and
`printf` writes the tab for you:

```bash
printf '%s\t%s\n' clip01.wav clip01.txt >> manifest.tsv
printf '%s\t%s\n' clip02.wav clip02.txt >> manifest.tsv
```

An optional third column names a keyterms file: one term per line (commas
and semicolons also separate terms). Export your FreeFlow vocabulary into
`vocabulary.txt` and add it to every line:

```bash
printf '%s\t%s\t%s\n' clip03.wav clip03.txt vocabulary.txt >> manifest.tsv
```

Relative paths are resolved from the manifest's folder, and `~/` works.
Lines starting with `#` are ignored. Ten to twenty clips is a good start.

## 4. Provide your keys

The tool asks only for the keys of the providers your variants use: Deepgram
for every variant without `provider=assemblyai`, AssemblyAI for the others (the
`providers` preset needs both).

### Deepgram

The tool reads the key from the `DEEPGRAM_API_KEY` environment variable. `read
-s` keeps the key off the screen and out of your shell history:

```bash
read -s DEEPGRAM_API_KEY; export DEEPGRAM_API_KEY
# ... runs ...
unset DEEPGRAM_API_KEY
```

You can instead pass `--key-file <path>`: a file holding only the key, on one
line, with `chmod 600`, outside every git repository (the tool refuses a key
file inside one). `--key-file` takes precedence over the environment variable.
The tool refuses a key file or `DEEPGRAM_API_KEY` that holds anything besides
one key (a second line, a comment, a space or a `NAME=value` entry) without
showing its contents, so no other credential reaches Deepgram. The key is never
printed or written anywhere; it goes only into the `Authorization` header.

### AssemblyAI

1. Sign up at [assemblyai.com](https://www.assemblyai.com) and open the
   dashboard. New accounts get free credits that cover streaming.
2. For zero data retention, turn off model training before you send any
   audio: on the dashboard's
   [Data Controls](https://www.assemblyai.com/dashboard/settings/data-controls)
   page, turn on **Opt Out of Data Sharing for Model Improvement Program**.
   AssemblyAI keeps no streaming audio or transcripts once you are opted out, but the page needs a paid plan (add a card first)
   and the Owner or Admin role, and the opt-out applies only to later
   sessions. On a free account your audio may be used for model training.
3. Copy a key from the **API Keys** page and export it the same way:

```bash
read -s ASSEMBLYAI_API_KEY; export ASSEMBLYAI_API_KEY
# ... runs ...
unset ASSEMBLYAI_API_KEY
```

The tool takes the AssemblyAI key from `ASSEMBLYAI_API_KEY` only (`--key-file`
is the Deepgram key), refuses a value that holds anything besides one key, never
prints it and sends it only in the `Authorization` header. A free account can
open 5 new streaming sessions per minute and a paid one 200; a refused session
shows as `account_limit`, so on a free account use `--concurrency 1` and
expect some of them on short clips.

## 5. Run experiments

```bash
"$REPLAY" run --manifest ~/FreeFlowAudioLab/manifest.tsv --variants determinism --out ~/FreeFlowAudioLab/results-determinism
```

Before anything is sent, the tool:

1. Decodes every file and prepares every audio variant. A problem, such as an
   unreadable file or isolation on a 16 kHz file, stops the run here, so it
   costs nothing.
2. Prints a plan: audio seconds × variants × repeats, the estimated cost, the
   estimated wall time, the variants and the output folder.
3. Asks `Send this audio to Deepgram?` (or names AssemblyAI, or both). Type
   `y` to continue. In a script, pass
   `--yes` instead; without a terminal and without `--yes`, it refuses. When
   you redirect the output to a file, the plan and the question still appear
   in the terminal.

Useful options: `--repeat N` (1 to 10 runs per file and variant), `--concurrency
N` (1 to 4 streams at once, default 2), `--save-transcripts`,
`--price-per-minute USD` and `--assemblyai-price-per-minute USD`. Use a new
`--out` folder for each experiment: the tool refuses a folder that already
holds a `results.csv`.

A suggested order:

1. `--variants determinism` first: the same settings three times. The spread
   between `same-1`, `same-2` and `same-3` is the noise floor. A later
   difference smaller than that spread means nothing.
2. On your Run Log WAVs: `--variants rate`, then `--variants endpointing`, then
   `--variants keyterms`, each with its own `--out` folder (for example
   `~/FreeFlowAudioLab/results-rate`).
3. Record masters for the capture-side questions. In QuickTime Player choose
   File > New Audio Recording, pick Maximum quality in the options menu next to
   the record button, and read the `SAY:` lines of `lab-script.txt`: once in a
   quiet room and once with a fan or music on. Shorter takes work better than
   one long file, because the paired statistics count files, so aim for 3 to
   5 script lines per take, each take with a reference `.txt` made of the
   matching `REF:` lines (section 3). Check every take:

   ```bash
   afinfo "$HOME/FreeFlowAudioLab/master-quiet-01.m4a"
   ```

   Look for 44100 or 48000 Hz and `lpcm` or `alac`. QuickTime's exact
   settings are not documented, so trust `afinfo` rather than the menu.
   Then run `--variants src` and `--variants isolation` on the masters.

## 6. What each preset answers

The first variant of each preset is the baseline for the paired comparison.
Every other setting stays at the tool's defaults, so each preset changes one
thing.

| Preset | Variants | Question |
|---|---|---|
| `rate` | `legacy24`, `dg16-minphase`, `dg16-mastering`, `dg48-native` | Is today's 16 -> 24 kHz stream worse than a clean 16 kHz one (PR 1)? On a 16 kHz Run Log WAV, `legacy24` reproduces today's upsampled stream, the two `dg16` variants send the WAV unchanged (they are identical), and `dg48-native` only upsamples. |
| `src` | `src-default`, `src-minphase`, `src-mastering-high` | On 44.1/48 kHz masters, does the converter quality matter? `src-default` stands in for an untouched converter. |
| `endpointing` | `ep10`, `ep300`, `ep500`, `ep1000`, `ep-false` | Which value should PR 2 use? `ep10` matches today's app, which sends no `endpointing` and so gets Deepgram's 10 ms default. Watch WER, first-word deletions and overlaps. |
| `keyterms` | `kt-all`, `kt-top20`, `kt-none` | Does a long keyterm list add false insertions? Needs the keyterms column in the manifest. |
| `language` | `lang-omit`, `lang-en`, `lang-en-US`, `lang-multi`, `lang-en-GB`, `lang-en-IN`, `lang-en-AU`, `lang-en-NZ` | Is omitting the language the same as `en`, is `multi` worse for English, and does Deepgram's regional English model suit your accent better? |
| `isolation` | `iso-off`, `iso-hq70`, `iso-hq100` | Does Apple's voice isolation (PR 3) help in noise or hurt in quiet? Needs 44.1/48 kHz masters and macOS 15. |
| `frames` | `f50`, `f20`, `f100`, `f250`, `f50-1.25x`, `f50-burst` | Do PR 2's 50 ms frames matter, and does sending faster than real time change results or latency? |
| `determinism` | `same-1`, `same-2`, `same-3` | How much do results vary when nothing changes? |
| `providers` | `dg-nova3`, `aai-u36`, `aai-u36-noprompt`, `aai-u36-nokt` | Is AssemblyAI Universal-3.6 Pro more accurate than Deepgram Nova-3 on your speech, and do its fixed prompt and its keyterms help? `dg-nova3` is today's app request with every keyterm; `aai-u36` is the app's AssemblyAI request with every keyterm and the general dictation prompt. Needs both keys (section 4); the keyterm variants need the keyterms column. |

On 48 kHz masters, `legacy24` first converts to 16 kHz with an untouched
`AVAudioConverter`. That is a stand-in, because the app's capture-side
converter is undocumented.

## 7. Reading the output

While it runs, the tool prints one line per stream, such as
`[3/40] ep500 item 2 repeat 1: ok`. The other statuses are `connect_failed`,
`http_NNN` (for example `http_401` for a refused key, which stops new streams),
`server_error`, `send_failed`, `closed_early` and `timeout`, and for AssemblyAI
also `key_refused` (which stops new streams too) and `account_limit` (its
new-sessions-per-minute limit or a low balance). Only `ok` runs are scored.

At the end it prints a table with one row per variant:

- **Files**: files with at least one `ok` run.
- **WER %**: word error rate over all `ok` runs: substitutions + deletions +
  insertions, divided by the number of reference words. Case and punctuation
  are ignored, and apostrophes inside words are kept.
- **S/D/I**: those three error counts. Many deletions mean words were lost.
- **1st/last del**: runs in which the first or the last reference word was
  deleted. These point at clipped starts and ends. When several alignments
  are equally good, a run counts if any of them deletes that word, so starts
  and ends are judged the same way.
- **KT recall**: keyterm occurrences in your references that the transcript got
  right, out of all those in the references.
- **KT false**: keyterm occurrences in the transcript beyond those in the
  reference. Over-boosted vocabulary shows up here.
- **Overlaps**: finalized segments whose first word starts before the previous
  segment's last word ends. The app drops a final that only repeats audio it
  already finalized, and a final that Deepgram re-sends from an earlier start
  replaces every final from that start on. Only a final that starts partway
  through an earlier one can still become duplicated words.
- **from_finalize p50/p95 ms**: milliseconds from the last audio frame to
  Deepgram's first `from_finalize` result, as the median and the 95th
  percentile. Deepgram sometimes sends none when little audio is left; those
  runs are left out.
- **Metadata p50/p95 ms**: the same, up to Deepgram's closing `Metadata`
  message.
- **Unfinal**: runs whose latest interim result still had words Deepgram never
  finalized. The app pastes those words after the finals instead of uploading
  the file, and its Run Log then shows `deepgram-final+interim-tail`. WER scores
  the finals only, so these tail words count as missing words here.
- **Failed**: runs that were not `ok`.

AssemblyAI rows use the same columns. Its stream starts at its `Begin`
message, as in the app, and ends like the app's release: `ForceEndpoint`, then
`Terminate`. Its finals are ended turns. **from_finalize** is the release-to-final
time: milliseconds from the last audio chunk to the first `end_of_turn` turn
after `ForceEndpoint`, missing when the turn had already ended in silence.
**Metadata** is the time to its closing `Termination` message, and a run is
`ok` only once that arrives, because by then every turn is flushed. **Unfinal**
counts runs that still had an unfinished turn with words. The table repeats
this mapping below itself when an AssemblyAI variant ran.

Below the table, the "Paired vs <baseline>" section compares each variant with
the first one, file by file, using each file's WER averaged over repeats:

- **Mean ΔWER pts**: the average change in percentage points. A negative value
  means fewer errors than the baseline.
- **Better/Worse/Same**: how many files improved, got worse or did not change.
- **Sign-test p**: how likely a split at least this lopsided would be if the
  variant made no difference. Below 0.05 is the usual bar. With fewer than 6
  files that changed, nothing can reach it (even 6-0 only just does), so
  compare the deltas with the determinism spread instead.

`results.csv` in `--out` holds one row per run with the same numbers (including
`formatted_wer`, `results` and `finals` counts) and no text. Rows are written
as each run finishes, so an interrupted run keeps what it has done. The exit
status is 0 only when every stream ran and returned `ok`.

## 8. Privacy

- Audio is sent only to the providers your variants name, only after you
  confirm. Deepgram gets it with `mip_opt_out=true` (opting out of Deepgram's
  Model Improvement Program) unless a variant changes it. AssemblyAI gets the
  audio, the variant's keyterms and its fixed scenario prompt (never any of
  your text); it retains nothing only when your account is opted out of model
  training (section 4).
- `--out` inside any git work tree is refused, and so is a `--key-file` inside
  one.
- `results.csv` and the terminal show only numbers, variant names, statuses and
  the paths you typed: never transcript text, the request URL (it carries your
  keyterms and, for AssemblyAI, the prompt), a key or a provider's error text.
- AssemblyAI bills the time a session is open, so the tool closes every session
  it opens: after `Termination`, after an error, when a send fails, and after
  10 seconds without `Begin` or without `Termination`. The request also sets
  AssemblyAI's 30-second `inactivity_timeout`, so the server ends a stalled
  session on its own.
- Transcripts are written only with `--save-transcripts`, as
  `transcripts/item001-<variant>-r1.txt` files with mode 0600 inside `--out`
  (folders are created with mode 0700). Files are never overwritten.
- When you are done, delete the lab folder (`rm -rf ~/FreeFlowAudioLab`) and
  never commit any of it.

## 9. Cost

The estimate is: total audio minutes × variants × repeats × price per minute.
The default price, $0.0077 per minute (Nova-3 streaming list price), is an
estimate that may be out of date for your plan. Add-ons such as keyterm
prompting may be billed separately. Use `--price-per-minute` for your plan's
rate, and check the usage page in the Deepgram console after a first small
run, such as two clips with `--variants determinism`.

AssemblyAI bills the time each session is open, not the audio. Its estimate
is, per stream, the audio at the variant's pace (real time, or 1/1.25 of it
for `pacing=1.25x`) plus about a second for the handshake and the final turn,
times $0.0075 per minute (the Universal-3.6 Pro streaming list price, which
may be out of date). Use `--assemblyai-price-per-minute` for your plan's rate.
When a run uses both providers, the plan shows each provider's estimate and
the total. Check the usage page in the AssemblyAI dashboard after a first
small run, such as two clips with `--variants providers`.

## 10. Writing your own variants

`--variants` takes a preset name or a file. A name that matches a preset and
contains no `/` is the preset, so write `./rate` to read a file called `rate`.
In a file, each line is `name key=value ...`, keys you leave out keep their
defaults, and the first line is the baseline. [`variants.example.txt`](variants.example.txt)
lists every key with its default and allowed values, plus examples: the
closest match to today's app request, a gain ladder and a larger keyterm
budget.

The defaults are `provider=deepgram rate=16000 src=minphase endpointing=500
language=en mip_opt_out=true smart_format=true punctuate=true
interim_results=true keyterms=none frame_ms=50 pacing=realtime isolation=off
gain_db=0`. As in the app, at most 100 keyterms (1,200 characters) are sent.

`provider=assemblyai` sends the app's AssemblyAI request instead: Universal-3.6
Pro, English, the variant's rate, and AssemblyAI's caps on keyterms (at most
100, each at most 50 characters). Three keys apply to it only:

- `prompt`: `dictation` (the default, the app's prompt for an ordinary text
  field), `coding`, `ai-chat`, `search`, `email`, `terminal`, or `off` for
  none. Each is one of the app's fixed one-sentence scenario prompts.
- `mode`: `default` (none sent, so the server picks, as in the app),
  `min_latency`, `balanced` or `max_accuracy`.
- `keyterms` works as for Deepgram.

The Deepgram query keys (`endpointing`, `language`, `mip_opt_out`,
`smart_format`, `punctuate`, `interim_results`) are refused with
`provider=assemblyai`, and `prompt` and `mode` without it. AssemblyAI closes a
session for audio chunks outside 50-1000 ms and processes at most about 1.25x
real time, so its variants need `frame_ms` 50-1000 and `pacing=realtime` or
`1.25x`. The tool rounds each chunk up to whole samples and pads a last chunk
shorter than 50 ms with silence, as the app does.
