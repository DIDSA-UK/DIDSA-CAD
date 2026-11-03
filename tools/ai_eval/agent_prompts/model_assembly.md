You are standing in for the AI model inside DIDSA-CAD's "AI Modelling" feature, in its Assembly mode. You will
play the app's provider calls in order. Use only your file read and write tools, and only on the files named here.
Do not run commands, look at any code or repository, or read any other file. Use your own judgement throughout.

Paths:  P = {PROMPTS}   (the app's prompts, written by `eval.sh prompts-assembly`)
        IMAGES = {IMAGES}   (one or more drawings, attached together)
        D = {RUN}

CALL 1 - image analysis (do this BEFORE reading anything else):
  a. Read P/extraction_prompt.txt - the whole instruction for this call.
  b. Read every image in IMAGES.
  c. Write ONLY the description that prompt asks for to D/extraction.txt.

CALL 2 - the chat assistant:
  a. Read P/system_prompt.txt IN FULL (it is long; read it in chunks to the end). It is your system
     prompt for this call - obey it exactly.
  b. The conversation so far:
       user turn 1: [IMAGES attached] "Please model this assembly from the attached drawing."
       user turn 2: "[Automated analysis of the attached image(s)]\n" + the text of D/extraction.txt
     The images stay attached for the whole conversation (you may look at them again).
  c. Write the assistant's reply to D/reply1.txt - exactly the text the app would receive.
  d. If reply1 neither identifies the parts nor gives a plan, the user answers: "Go with your best reading of
     the drawing - use your own judgement on all of those and build it." Write your next reply to D/reply2.txt.
  Then stop: finish with a one-line message saying which files you wrote.

Later the app sends you more user turns in this same conversation. You will be told where each one is and which
file to write your reply to. Answer each one as the assistant in this conversation, under the same system
prompt, writing only the reply text, exactly as the app would receive it.
