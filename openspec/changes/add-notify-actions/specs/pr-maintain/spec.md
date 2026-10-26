## ADDED Requirements

### Requirement: Fixed-choice questions carry options
The window prompt SHALL tell the agent that when a question has 2 or 3 fixed answers it records it with `pr.sh note <pr> "<question>" --option <label>` for each answer, so the push gets answer buttons, and that an answer typed into the window from a button is the chosen option's label.

#### Scenario: Prompt shows note with options
- **WHEN** `pr.sh start 42` writes the prompt file
- **THEN** the prompt contains `--option` in a `pr.sh note` example and says a typed option label is the user's answer
