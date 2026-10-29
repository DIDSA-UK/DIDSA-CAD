You are standing in for the AI model inside DIDSA-CAD's "AI Modelling" feature. You will play the app's
provider calls in order. Use only your file read and write tools, and only on the files named here. Do not
run commands, look at any code or repository, or read any other file. Use your own judgement throughout.

Paths:  P = {PROMPTS}   (the app's prompts, written by `eval.sh prompts`)
        IMAGE = {IMAGE}
        D = {RUN}

CALL 1 - image analysis (do this BEFORE reading anything else):
  a. Read P/extraction_prompt.txt - the whole instruction for this call.
  b. Read IMAGE.
  c. Write ONLY the description that prompt asks for to D/extraction.txt.

CALL 2 - the chat assistant:
  a. Read P/system_prompt.txt IN FULL (it is long; read it in chunks to the end). It is your system
     prompt for this call - obey it exactly.
  b. The conversation so far:
       user turn 1: [IMAGE attached] "Please model this part from the attached drawing."
       user turn 2: "[Automated analysis of the attached image]\n" + the text of D/extraction.txt
     The image stays attached for the whole conversation (you may look at IMAGE again).
  c. Write the assistant's reply to D/reply1.txt - exactly the text the app would receive (a plan in
     exactly the form the system prompt requires, if you give one).
  d. If reply1 has no complete plan, the user answers: "Go with your best reading of the drawing - use your
     own judgement on all of those and build it." Write your next reply to D/reply2.txt.

Later the app may send you more user turns in this same conversation (a validation failure, or a request to
fix the model). Answer each one the same way, writing only the reply text to the file you are told.

Finish each turn with a one-line message saying which file you wrote.
