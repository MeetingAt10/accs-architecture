# 0003. Use one DynamoDB table as the application database

- Status: Superseded by [0004](0004-dynamodb-domain-tables.md)
- Date: 2026-11-01

## Context

The backend keeps all application data (users, spaces, posts, reports, consultations, evaluations, notifications, audit entries) in memory as synthetic demo data, so every Lambda cold start resets it and each instance holds its own copy. Accounts and password hashes live in one JSON object in `AuthStoreBucket`, written with a conditional put; concurrent writes conflict on the single object and the approach does not scale past a demo.

The API runs on Lambda behind an HTTP API, so the database must handle many short-lived connections and cost nothing when idle.

## Decision

Add `templates/database.yaml`, a `Database` nested stack in `envs/dev/main.yaml`, creating one DynamoDB table `accs-dev-app`:

- On-demand billing (`PAY_PER_REQUEST`); no capacity to manage, idle cost is only storage.
- Generic keys `PK`/`SK` plus two overloaded GSIs (`GSI1`, `GSI2`), all strings, projection `ALL`.
- TTL on `expiresAt` (epoch seconds) for password reset codes and sessions.
- Point-in-time recovery, deletion protection, `DeletionPolicy: Retain`. Encrypted at rest with the AWS owned key.
- The API Lambda gets `TABLE_NAME` and item-level actions (get, batch get, query, put, update, delete, batch write, condition check) on the table and its indexes. No `Scan`: every access path is designed as a key lookup or query.

### Key design

| Entity | PK | SK | GSI1PK / GSI1SK | GSI2PK / GSI2SK |
|---|---|---|---|---|
| User profile | `USER#<id>` | `PROFILE` | `EMAIL#<email>` / `USER` | `ROLE#<role>` / `<name>` |
| Credential | `USER#<id>` | `CREDENTIAL` | | |
| Reset code | `USER#<id>` | `RESET` (+ `expiresAt`) | | |
| Student ID lookup | `STUDENTID#<studentId>` | `USER` (holds user id) | | |
| Space | `SPACE#<id>` | `META` | | `PROGRAM#<program>` / `<section>` |
| Space member | `SPACE#<id>` | `MEMBER#<userId>` | `USER#<userId>` / `SPACE#<id>` | |
| Post / thread | `SPACE#<id>` | `POST#<createdAt>#<id>` | `POST#<id>` / `META` | `AUTHOR#<userId>` / `<createdAt>` |
| Comment / message | `POST#<id>` | `COMMENT#<at>#<id>` | | `AUTHOR#<userId>` / `<at>` |
| Report (case) | `REPORT#<id>` | `META` | | `STAGE#<stage>` / `<updatedAt>` |
| Report history / notes | `REPORT#<id>` | `HISTORY#<at>#<id>`, `NOTE#<at>#<id>` | | |
| Faculty slot | `FACULTY#<id>` | `SLOT#<date>#<start>` | | |
| Consultation | `CONSULT#<id>` | `META` | `STUDENT#<id>` / `<createdAt>` | `FACULTY#<id>` / `<createdAt>` |
| Evaluation cycle | `CYCLE#<id>` | `META` | | `STATUS#<status>` / `<opens>` |
| Assignment | `CYCLE#<id>` | `ASSIGN#<id>` | `EVALUATOR#<userId>` / `<cycleId>` | `FACULTY#<id>` / `EVAL#<cycleId>` |
| Restriction / referral | `USER#<studentId>` | `RESTRICTION#<id>`, `REFERRAL#<at>#<id>` | | |
| Notification | `USER#<id>` | `NOTIF#<at>#<id>` | | `UNREAD#<userId>` / `<at>` (removed when read) |
| Audit entry | `AUDIT#<yyyy-mm-dd>` | `<at>#<id>` | `ACTOR#<userId>` / `<at>` | `MODULE#<module>` / `<at>` |
| Moderation item | `MODERATION#<id>` | `META` | `ITEM#<itemId>` / `MODERATION` | `MODSTATUS#<status>` / `<at>` |

Uniqueness of email and student ID is enforced with a transaction that puts the user and the `STUDENTID#`/`EMAIL#` guard items with `attribute_not_exists(PK)`.

## Migration

1. Deploy the stack; the table is created empty and the Lambda gets `TABLE_NAME`.
2. Backend adds a DynamoDB repository and auth store behind the existing `Repository` / `AuthStore` interfaces, selected when `TABLE_NAME` is set; memory and file stores stay for tests and local work.
3. One-off script copies `auth-store.json` accounts into the table and seeds demo data.
4. After the backend reads from DynamoDB in dev, remove `AuthStoreBucket` access from the Lambda role; the bucket itself is retained.

## Consequences

- Data survives cold starts and is shared by every Lambda instance; writes are per item, so concurrent registrations no longer conflict.
- Access patterns must be designed up front; a new query that fits no key or index needs a new GSI (online, no downtime).
- Reports and dashboards that need ad hoc filtering go through GSI queries or a later export, not table scans.
- Cost at dev scale is cents per month: on-demand requests plus storage (first 25 GB free), and PITR adds a per-GB charge.
