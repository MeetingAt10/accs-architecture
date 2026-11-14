# 0006. Rule-based context-aware escalation, no LLM

- Status: Proposed
- Date: 2026-11-09

## Context

The study title promises "Context-Aware Grievances Escalation". The engine must detect when a report is about the reporter's adviser or another handler, route around that person, and group similar reports (proposal objective 1). The proposal and consultations never name a method.

Two families were considered:

1. An external large language model reads the report and returns structured facts; code routes.
2. A deterministic pipeline: roster-based alias matching, fuzzy string similarity, keyword lexicons, TF-IDF cosine similarity and a routing decision table.

Constraints:

- The proposal keeps NLP models as future work (line 145) and rules out autonomous decisions (line 109).
- Reports are the most confidential records in the system (`ccs_grievance`, ADR 0004). Sending them to an outside service raises Data Privacy Act (RA 10173) questions.
- The panel must be able to see why each report went where it went.
- The API runs on Lambda Node 22 with no paid AI service in the budget.

## Decision

Use the deterministic pipeline. No LLM, embedding API or other external AI service takes part in routing or grouping.

- "Context" means the reporter's roster links (adviser, subject professors, Program Chair, Dean) and their alias sets.
- Mention detection: exact multi-pattern matching plus Jaro-Winkler fuzzy matching against those aliases.
- Target detection: proximity of a mention to a complaint-lexicon term gives a conflict score.
- Grouping: TF-IDF vectors and cosine similarity, threshold from settings (draft 0.80).
- Routing: a decision table on the existing stage machine.
- The engine runs in the existing API Lambda. Lexicons and thresholds are versioned settings.

The full specification is the delta `accs-docs/deltas/2026-11-09-context-aware-escalation-engine.md`.

## Consequences

- Every decision is explainable: the matched alias, the matched term, the scores and the rule are stored and shown to the handler.
- No report text leaves AWS. No new cost or vendor.
- Results are reproducible, so a labeled test set can serve as a regression suite.
- Indirect references with no name or role word are missed. They fall to Program Chair triage or the student's own "about my adviser" answer.
- Lexicons need maintenance each semester (Taglish slang changes).
- If accuracy on the test set is not enough, a classical classifier (for example Naive Bayes) can be added later without changing this decision's privacy property.
