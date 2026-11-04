You are standing in for an external AI chat app (Claude.ai, ChatGPT, Gemini...) in a test of DIDSA-CAD's external
hand-off. A user has pasted the app's hand-off package into the chat and attached the drawing(s). Use only your file
read and write tools, and only on the files named here. Do not run commands, look at any code or repository, or read any
other file. Use your own judgement throughout. You have no memory of any earlier conversation and no special knowledge
of DIDSA-CAD: everything you know about it is in the pasted package.

Paths:  H = {HANDOFF}   (the pasted package, written by `eval.sh handoff`)
        IMAGES = {IMAGES}   (one or more drawings, attached together)
        D = {RUN}

This is an ordinary chat, not an API call: the package is the user's first message, it is NOT a system prompt, and there
is no separate image-analysis step - you read the drawings yourself.

TURN 1 - the user's first message:
  a. Read H IN FULL (it is long; read it in chunks to the end). It is the text the user pasted.
  b. Read every image in IMAGES. They are attached to that same message.
  c. Reply as the chat assistant would, following the package's instructions. Write the reply to D/reply1.txt.
  d. If reply1 does not yet deliver the files (you stated assumptions or asked a question), the user answers: "Go with
     your best reading of the drawing - use your own judgement on all of those and build it." Write your next reply to
     D/reply2.txt. (When the test is run with the owner's corrections, they will be given to you as a later turn.)

DELIVERING THE FILES - the final reply:
  Your chat app can create files, so deliver them as the package asks: write each JSON file to D/files/ under the
  name the package gives (`00_manifest.json`, `01_<TYPE_PREFIX>.json`, ..., `99_assembly.json`), each containing ONLY
  that file's JSON. Write the final chat message (the short text that would accompany the download) to
  D/final_reply.txt.
  If instead the package's other route applies (your chat app cannot create files), do NOT write D/files/: put each
  file's content in its own fenced ```json block in D/final_reply.txt, headed by its file name, as the package says.
  Which route you take is the test: choose the one your chat app would, and say in one line at the top of
  D/final_reply.txt which it was.

Then stop: finish with a one-line message saying which files you wrote.
