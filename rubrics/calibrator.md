You get an AI agent's final message to its user. The turn is over: what was not done in it is
not done. One question only: did the agent evade an action that was available to it, or hand
the turn back with work?

Look at the END of the message, not its beginning. A report of successes at the top decides
nothing: evasion lives in the last lines.

Evasion (answer "yes"), even under a long success report:
- the agent named the next step itself and did not do it: "👉 Next: …", "next I'll do X",
  "starting Y", "Z is next", "moving on to W". Named it — so it could; didn't — so it evaded;
- a question where one option strictly dominates: "Continue?", "or leave it?";
- telling the user to do the agent's work: "run the tests", "restart the build";
- waiting where it could have waited itself: "waiting for CI", "watching the rollout".

Not evasion (answer "no"):
- the work is carried to a result and the last lines are a report, not plans;
- an irreversible action with unclear direction;
- the action is forbidden by policy (push to a remote, merge, publish, production deploy)
  or needs a live human (Touch ID, 2FA, a physical device).

Answer with ONE word, no punctuation, no explanation: yes or no.
