# Flutter widget-test lessons

Reference doc distilled from standing up real CI for the client for the first
time (`docs/status.md`'s 2026-07-08 entries have the full incident history)
and then getting it from 26 real failures down to 1 confirmed environment
flake, across nine CI round-trips. This file is the "how do I write/fix a
widget test correctly the first time" lookup; `status.md`/`roadmap.md` are
dated narrative logs, not meant to be searched for a recipe. Everything here
was learned the hard way - by guessing wrong at least once, then reading a
real CI failure to find out why.

## The one meta-lesson everything else follows from

**A test failure's own words are more trustworthy than any theory about why
it failed.** Every mistake in this list was caused by fixing what a failure
*probably* meant instead of what its actual finder/assertion output said.
Conversely, every real fix came from reading the exact "Found N widgets" /
"Actual: X" text and tracing it to a specific line of app or test code - not
from pattern-matching against a similar-looking failure seen earlier. When a
fix is pushed, the only real confirmation is the next CI run's actual output,
not "this looks like it should work now." Several rounds in this project's
own history re-broke a test while fixing another one in the same file, or
introduced a new bug while fixing the reported one - caught only because
each round re-checked the real log instead of assuming green.

## `find.byTooltip(...)` is unreliable for tapping

`find.byTooltip('Add')` finds the `Tooltip`/`RawTooltip` widget wrapping a
button, but tapping it taps at *that widget's own computed position* - which
is not reliably the same as the wrapped button's actual center. This bit us
twice, in two different ways:

- The tooltip's own position can land **outside the test viewport's bounds**
  entirely (`Offset(825.6, 144.0)` on an 800x600 surface) if the underlying
  button is mid-transition (see the Hero section below).
- The tooltip's position can land **inside the viewport but on top of a
  different widget** (obscured/absorbed), with no "outside bounds" hint at
  all - just a plain "would not hit test on the specified widget" warning.

**Fix**: for anything you need to *tap*, use `find.widgetWithIcon(<ButtonType>,
<Icon>)` (or `find.byKey` if the widget has one) instead of `find.byTooltip`.
Reserve `find.byTooltip` for existence/count assertions
(`expect(find.byTooltip('Add'), findsOneWidget)`), where its ambiguity about
*position* doesn't matter.

## `pumpAndSettle()` fails forever against a permanently-running `Ticker`

Any widget that starts its own `Ticker`/`AnimationController` unconditionally
in `initState()` - not tied to a specific user gesture - keeps scheduling
frames indefinitely, so `pumpAndSettle()` never returns (it waits for frame
scheduling to *stop*). Two real widgets in this codebase do this on purpose:

- `PartViewport` shows a `CircularProgressIndicator` while `Scene
  .initializeStaticResources()` is pending, and separately drives ongoing
  render state.
- `SketchCanvas` starts an edge-pan `Ticker` unconditionally in `initState`
  (for edge-panning during a drag near the canvas edge), regardless of
  whether a drag is in progress.

**Fix**: never call `pumpAndSettle()` against a widget tree containing either
of these (or anything with a similar always-on `Ticker`). Use a bounded
sequence instead - `await tester.pump(); await tester.pump(const
Duration(milliseconds: 250));` for a fixed, known-short animation, or the
`_pumpUntil` helper pattern (see below) for anything gated on an async
round-trip.

## Waiting for an async round-trip: `_pumpUntil`, not a fixed-duration pump

A fixed `await tester.pump(const Duration(milliseconds: 250));` only works if
250ms is *reliably* enough time for whatever async work needs to finish
first. It is not, for anything that awaits a network call (even to an
in-memory `MockClient`) before showing UI - `previewCascadeDelete`'s GET
before `showCascadeDeleteDialog`, `getProfile`'s GET before a long-press
context menu shows Extrude's eligibility, etc. A fixed pump that happens to
work today can start failing the moment the awaited call chain gets one
network round-trip longer.

**Fix**: use a bounded polling helper (already present in several test files
as `_pumpUntil`) that pumps repeatedly until a specific finder condition
becomes true, with a `maxPumps` cap:

```dart
Future<void> _pumpUntil(WidgetTester tester, bool Function() done, {int maxPumps = 100}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}
```

Wait for the *specific widget the next action needs*, not just "some text
appeared" - see the AlertDialog section below for why that distinction
matters.

## Wait for the specific widget you're about to interact with, not a proxy signal

Two different proxy-signal mistakes, both from this same project:

- **A collapsed `ExpansionTile`'s children aren't in the render tree at all**
  until it's expanded - not just invisible. A test that opens a toolbar panel
  and then immediately searches for a child inside a collapsed
  `ExpansionTile` section will get "Found 0 widgets", not "found but not
  visible". Tap the section header first.
- **"Spinner gone" is not the same signal as "the real interactive widget
  tree is mounted."** `PartViewport.build()` stops showing its
  `CircularProgressIndicator` in *two* different cases: `Scene` setup
  succeeded (`_scene != null`, the real `Listener`-wired tree), or it failed
  (`_error != null`, a plain error `Text` with no `Listener` at all). A test
  that waits only for the spinner to disappear can end up tapping the
  error-state fallback, where the tap silently hits nothing. Wait for the
  actual widget the next step needs (`find.descendant(of: find.byType(X),
  matching: find.byType(Listener))`), not an indirect proxy for "probably
  ready by now."

## Scope your finder to the widget you actually mean

`find.byType(Listener)` (or any widget type common enough to appear in
framework internals - `Scaffold`, `GestureDetector`, `Padding`, etc.) can
match an ambient instance somewhere else in the tree, not the one you're
trying to test. Two real instances:

- `find.byType(Listener)` matched a `Listener` created internally by
  `Scaffold`/`GestureDetector` machinery, returning true on the very first
  frame - before `PartViewport`'s *own* `Scene` setup had actually finished,
  completely defeating the wait it was meant to provide.
- `find.descendant(of: find.byType(DraggableScrollableSheet), matching:
  find.byType(Padding)).first` picked `SafeArea`'s *own* internal `Padding`
  (used for the device's safe-area insets, zero in a test environment), not
  the app's own explicit `Padding(right: 72)` nested one level deeper as its
  child - `SafeArea`'s implementation wraps its child in a `Padding` of its
  own, ahead of anything the app code adds.

**Fix**: scope with `find.descendant(of: ..., matching: ...)` down to the
specific widget under test, and when a plain-type or plain-text search could
plausibly match more than one thing, match on a specific property instead
(`find.byWidgetPredicate((w) => w is Padding && (w.padding as
EdgeInsets).right == 72)`, `find.descendant(of: find.byType(AlertDialog),
matching: find.text('Delete'))`).

## `heroTag` means a widget can transiently exist twice

Any widget wrapped in a `Hero` (including a `FloatingActionButton` with an
explicit `heroTag`) can have a temporary in-flight copy overlaid on top of
the destination route's own static widget while a push/pop transition's Hero
flight is still animating. A `find.widgetWithIcon(FloatingActionButton,
Icons.add)` search during that window can find **two** matches - the
in-flight copy and the real one - not just the real one arriving late.

**Fix**: don't guess a settle duration. Wait for the ambiguity to actually
resolve - e.g. `_pumpUntil(tester, () =>
find.widgetWithIcon(FloatingActionButton, Icons.add).evaluate().length ==
1)` - since the *duration* of a Hero flight isn't a fixed, safe-to-hardcode
number the way a single MaterialPageRoute's own transition curve might
suggest.

## A fake/mock backend must implement every endpoint the real code path
calls - not just the ones a test originally exercised

`_FakeDocumentBackend` (this project's in-memory `/document` API fake) never
implemented `GET .../features/{id}/cascade-preview` - the read-only preview
`_cascadeDeleteFeature` awaits *before* it even shows its confirmation
dialog. Every long-press-Delete test in the file was hitting a 404 on that
call and silently failing before the dialog ever rendered - and no amount of
`_pumpUntil` waiting could ever have fixed that, since the dialog genuinely
never appeared. This wasn't a timing bug at all; it looked like one until
the actual HTTP path was checked against what the fake backend's `handle()`
method actually matched.

**Fix**: when a test's own finder failure suggests a dialog/panel "never
opens" rather than "opens too slowly", check whether every network call the
code path awaits *before* that dialog/panel actually has a handler in the
test's fake backend - a missing route is indistinguishable from a slow one
until you check.

## Telling a stale test apart from a real app bug

A failing test is not automatically a regression. This project's own history
has real, confirmed examples of both, and the tell is usually in the code's
own comments or its git history, not in guessing which is more likely:

- **Stale test**: the app's own doc comment states an intentional,
  already-shipped behavior change (e.g. `_onFeatureTap`'s own comment:
  "no longer gated on `!feature.locked`" - B4's true-rollback change) that
  directly contradicts what an older test still asserts. Fix the test to
  match the documented intent, not the app.
- **Real bug**: a constant's value contradicts the reasoning in the comment
  sitting directly above it (`_defaultDistance = 80` right below a comment
  deriving "~48.28, rounded to a clean 48") - the code and its own
  justification disagree, not test vs. code. Fix the code.
- When genuinely unsure, `git show <commit>` on whatever introduced the
  current behavior settles it - `orbit_camera_test.dart`'s far-clip
  expectations were confirmed stale (not a regression) by finding the exact
  commit that intentionally bumped `kDefaultFarClip` from 1000 to 3000,
  which the test was simply never updated to match.

## Recognizing genuine CI-sandbox environment flakiness (and when to stop)

Not every remaining red test is a bug reachable from source or test-file
changes. `ubuntu-latest` GitHub Actions runners have no real GPU - Flutter's
Impeller/`flutter_gpu` backend is unavailable, and `Scene
.initializeStaticResources()` can resolve to a real, already-understood
error (`Flutter GPU requires the Impeller rendering backend, but Impeller is
not enabled`) inconsistently across otherwise-identical runs, for specific
widget configurations. The tell that this is environment flakiness and not
a lingering code bug: the *exact same* error reproduces verbatim across
multiple runs (not a new/different error each time), and a structurally
similar sibling test in the same file only "passes" because its own
assertions happen to hold whichever way Scene setup resolves - it never
actually depends on the distinction the flaky test does. Once that's
confirmed, further pump-budget or wait-condition tweaking is chasing an
environment limit, not a bug - document it and stop, rather than guessing
indefinitely at fixes for something no test-file change can actually fix.

## The `flutter_scene`/`flutter_gpu` CI channel pin

Unrelated to test-writing mechanics, but worth restating here since it's the
precondition for any of the above being reachable at all: this repo's CI
must use `channel: master` (not `stable`) in `subosito/flutter-action@v2` -
`flutter_scene 0.18.1` depends directly on `flutter_gpu`'s still-experimental
API surface, which current stable Flutter has already changed underneath it.
See `.github/workflows/client-verify.yml`'s own comment and `docs/status.md`'s
"flutter_scene 0.18.1 doesn't compile against current Flutter stable at all"
entry for the full story.

## Beyond widget tests: real on-device screenshots against a real backend

**Reserve this for significant, tough, or unexpectedly-tricky work** - it's a
genuine time investment (bootstrapping a whole toolchain from nothing), not a
routine step for every change. `flutter test`/`flutter analyze` stay the
default first line; reach for this when the stakes or surprise factor
justify it - new canvas/rendering code, a fix that "should obviously work"
but something about it still nags, a bug that won't reproduce any other way.

The reason it's worth the cost: a widget test only proves the *widget tree*
is right - it asserts on finders and structure, never on what actually gets
*painted*. That gap is real, not theoretical. Building `GearDesignScreen`'s
2D preview canvas (`docs/status.md`'s 2026-08-04 Workstream 8 entry has the
full story), two real bugs - a `CustomPaint` that silently collapsed to zero
height, and a `canvas.drawCircle` that rendered as a filled square under this
project's own required Impeller/master-channel toolchain - both passed every
widget test and a clean `flutter analyze` outright, because neither check
ever looks at a rendered pixel. Only actually running the compiled app and
looking at a real screenshot caught them, and only re-running the same way
after each fix actually confirmed it (not "this looks like it should render
now" - the same "trust the real output, not a theory" meta-lesson at the top
of this file, just applied to a screenshot's pixels instead of a test
runner's assertion text).

### The recipe (a fresh container has none of this installed - bootstrap all of it)

1. **A real Flutter SDK on this project's actual channel**: `git clone -b
   master --depth 1 https://github.com/flutter/flutter.git` - **`master`,
   not `stable`** (see the channel-pin section above), or `flutter_scene`/
   `flutter_gpu` fail to even compile.
2. **Linux desktop build deps** (also missing fresh): `apt-get install -y
   libgtk-3-dev libepoxy-dev libgl1-mesa-dev pkg-config`, then `flutter
   config --enable-linux-desktop && flutter build linux --debug` - a real
   compiled binary (`build/linux/x64/debug/bundle/<app>`), not `flutter
   run`'s dev-mode wrapper.
3. **A display to run it against**: `apt-get install -y xvfb`, `Xvfb :99
   -screen 0 1280x800x24 &`, `export DISPLAY=:99`.
4. **A real backend, not a mock** - for this project, the same
   `pythonocc-core` conda env bootstrap `docs/status.md`'s Workstream 1-2
   entry already describes, `uvicorn app.main:app --host 127.0.0.1 --port
   8123` in the background. A mocked `MockClient` widget test can't catch a
   rendering bug that only shows up against real response shapes.
5. **Drive it**: `apt-get install -y xdotool`, then `xdotool mousemove X Y
   click 1` / `xdotool type --delay 40 "text"` against absolute screen
   coordinates - there's no window manager under Xvfb, so no window
   IDs/focus concepts to fight, the app just fills the whole display. Clear
   a field before typing over it - `xdotool key ctrl+a` then `key Delete` -
   don't assume a click selects existing text; a stale/pre-filled value
   (this project persists server URL/API key via `shared_preferences`) gets
   new text **appended**, not replaced, otherwise. A screenshot right after
   typing, before the next click, is the cheap way to catch that before it
   wastes a whole later step.
6. **Look at it for real**: `pip install pillow`, then
   `PIL.ImageGrab.grab().save(path)` - captures the real X11 framebuffer
   directly against Xvfb, no extra system screenshot tool (`scrot`/`xwd`)
   needed. Read the saved PNG back with the Read tool; sample specific
   pixels (`img.getpixel((x, y))`) to confirm an exact colour when a
   screenshot merely *looks* right but the actual claim is about a specific
   value.
7. **A built Linux binary's own GPU-enablement gap**: launched directly
   (not via `flutter run`), it needs `FLUTTER_ENGINE_SWITCHES=1
   FLUTTER_ENGINE_SWITCH_1="enable-flutter-gpu=true"` set before launch or
   `PartViewport`'s 3D scene refuses to start - and the index is **1-based**
   (`FLUTTER_ENGINE_SWITCH_0` is rejected with a "FLUTTER_ENGINE_SWITCH_1 is
   missing" error, not the `_0` its own naming suggests). Same underlying
   gap `client/README.md` already documents for `flutter run -d windows`.

### Rough edges hit doing this, so the next session doesn't rediscover them

- `pkill -f <name>` in this sandbox's Bash tool can report a spurious "Exit
  code 144" even when it worked fine (or had nothing to kill) - don't trust
  it as a success/failure signal. Confirm with `ps aux | grep <name>`, and
  prefer `kill -9 <pid>` (tracked from the `nohup ... & echo $!` launch)
  over `pkill` when precision matters, e.g. relaunching after a rebuild
  without killing a second stray instance too.
- Rebuilding after an on-device fix means a full `flutter build linux
  --debug` (tens of seconds, not instant) - budget for a real rebuild-and-
  reverify loop per fix, not a single pass.
