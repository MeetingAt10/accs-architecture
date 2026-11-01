# 0004. Use twelve DynamoDB domain tables from the DOC006 data dictionary

- Status: Accepted
- Date: 2026-11-02
- Supersedes: [0003](0003-dynamodb-single-table.md)

## Context

ADR 0003 created one table, `accs-dev-app`, with two overloaded indexes. The project's data dictionary, DOC006 (`DOC006_DATA-DICTIONARY.new.docx`, the canonical version), specifies twelve tables instead, one per domain, holding 89 item types and 36 indexes. It gives the reasons for stopping at twelve rather than one:

- IAM blast radius: `ccs_discipline` and `ccs_grievance` hold the most confidential records, and separate tables let a policy reach the forum without any path to an offense record.
- Write pattern: `ccs_audit` is append-only and high-volume, and can be granted put-only access.
- Retention: TTL is a table-level setting; sessions, login attempts, notifications, and chat transcripts expire, while offense records and case files must not.
- Readability: the twelve tables map onto the twelve domains of the proposal.

`accs-dev-app` held no production data when this was decided; the backend had not shipped code that writes to it.

## Decision

`templates/database.yaml` creates the twelve DOC006 tables, named `<TablePrefix><table>` (dev: `accs-dev-ccs_identity`, …):

| Table | Indexes | TTL attribute |
|---|---|---|
| `ccs_identity` | GSI1–GSI3 | `expires_epoch` |
| `ccs_academic` | GSI1–GSI3 | |
| `ccs_community` | GSI1–GSI3 | |
| `ccs_messaging` | GSI1–GSI3 | |
| `ccs_moderation` | GSI1–GSI2 | |
| `ccs_scheduling` | GSI1–GSI4 | |
| `ccs_grievance` | GSI1–GSI6 | |
| `ccs_evaluation` | GSI1–GSI4 | |
| `ccs_discipline` | GSI1–GSI3 | |
| `ccs_notification` | GSI1 | `purge_epoch` |
| `ccs_assistant` | GSI1–GSI2 | `purge_epoch` |
| `ccs_audit` | GSI1–GSI2 | |

- Keys are generic strings `PK`/`SK`; index keys are `GSInPK`/`GSInSK`, projection `ALL`. Item types, key patterns, and attribute names (snake_case, `entity_type` on every item) follow DOC006.
- Every table: on-demand billing, point-in-time recovery, deletion protection, `DeletionPolicy: Retain`, AWS owned key.
- The API Lambda gets `TABLE_PREFIX` and item-level actions on the eleven business tables and their indexes, without `Scan`. On `ccs_audit` it gets only `PutItem`, `GetItem`, `BatchGetItem`, `Query`, and `ConditionCheckItem`: it cannot update or delete an audit entry.
- The root stack outputs `TablePrefix`. The `Api` stack depends on `Database`, since its policy names the tables.

### Deviations from DOC006 (to be amended in the document)

1. `ccs_identity` names two TTL attributes (`expires_epoch` on SESSION, `purge_epoch` on LOGINATTEMPT). DynamoDB allows one per table, so every expiring item in `ccs_identity` uses `expires_epoch`.
2. SESSION: `session_id` is the SHA-256 of the cookie token, not the token itself, so a leaked table or backup cannot be replayed as live sessions. `remember` (BOOL) is added to select the idle timeout.
3. RESET is a new `ccs_identity` item type for password reset codes (DOC006 has none): `PK = USER#<user_id>`, `SK = RESET`, attributes `user_id`, `code_hash`, `code_expires_at`, `attempts`, `issued_count`, `window_start`, `issued_by`, `expires_epoch` (TTL, kept until both the code and the hourly issue window are over).

## Migration

1. Deploy the stack. The twelve tables are created empty and the Lambda gets `TABLE_PREFIX` instead of `TABLE_NAME`.
2. `accs-dev-app` is removed from the template. Its `DeletionPolicy: Retain` keeps it in the account as an unmanaged table; delete it by hand (turn off deletion protection first) once nothing reads it.
3. The backend moves entities onto the tables domain by domain, starting with sessions and reset codes in `ccs_identity`.
4. The auth store bucket stays until accounts and credentials move into `ccs_identity`.

## Consequences

- Twelve tables to monitor and back up instead of one; at dev scale the cost is still on-demand requests plus storage, with PITR charged per GB.
- An access pattern that fits no key or index needs a new GSI on its domain table (online, no downtime).
- A transaction that spans domains (for example a report plus its audit entry and notifications) is a `TransactWriteItems` across tables, which DynamoDB supports within one region and account; the 100-item limit applies.
