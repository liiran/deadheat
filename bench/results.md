# Results

Every number here comes from a run of a script in this folder; the command is next to it. Runs were on
a Windows 11 desktop (Ryzen 5 9600X) with everything in Docker: Ruby 3.4 (Ruby 4.0 for today's
Lobsters), Rails 8.1, PostgreSQL 17, MySQL 8.4, MariaDB 11.4 and SQLite 3.

## 1. Corner Store: Dead Heat against the tools Rails developers already use

[`demo/`](../demo) is a small Rails 8 store with ten races planted in realistic features. Each feature
has a fixed twin and an ordinary test, and all 32 of its tests pass. The question is how many of the ten
each tool points at, and whether any tool raises an alarm on a fixed twin.

```
docker compose run --rm -e DB=postgres dev ruby bench/tools_bench.rb
```

| Tool | PostgreSQL | MySQL | SQLite | Alarms on fixed twins | Messages printed |
| --- | --- | --- | --- | --- | --- |
| The app's own tests | 0 / 10 | 0 / 10 | 0 / 10 | 0 | 0 |
| database_consistency 3.1 | 1 / 10 | 1 / 10 | 1 / 10 | 0 | 41–54 |
| active_record_doctor 2.1 | 1 / 10 | 1 / 10 | 1 / 10 | 0 | 25–45 |
| Dead Heat scan | 10 / 10 | 10 / 10 | 10 / 10 | 0 | 13 |
| **Dead Heat sweep** | **10 / 10** | **10 / 10** | **9 / 10** | **0** | 10 |

- **What the two tools catch:** only the race that is a uniqueness validation without a unique index
  (the newsletter). That's the only kind they check for. Most of their messages are about other
  things (`NOT NULL` without a presence validator, missing `dependent:` options).
- **How the matching was scored:** each of their messages was counted only when it was about uniqueness.
- **SQLite:** Rails 8 runs SQLite writes with `BEGIN IMMEDIATE`, so the newsletter's validate-then-insert,
  done inside one transaction, really can't race there. The sweep is right not to report it.
- **Irreversible:** two of the ten races sent something that can't be taken back. One was a second
  order confirmation email (a queued `OrderMailer` job); the other was a second `ShipOrderJob`.
- **Coverage:** the sweep reached 23 of the app's 28 write endpoints (82%) from its existing tests. The
  other five include two admin endpoints that have no tests. The scan still flagged one of those, the
  admin restock (stock added up in Ruby), which is a real race.

## 2. Lobsters: a real race, before and after its fixes

[Lobsters](https://github.com/lobsters/lobsters) fixed a race in `Domain#find_or_create_origin` in
December 2024. Two stories from the same new site at once could both insert the same origin, and the
unique index stopped the second with an unhandled `ActiveRecord::RecordNotUnique`. The race test is ten
lines ([`historical/lobsters/origin_race_spec.rb`](historical/lobsters/origin_race_spec.rb)), and
[`historical/run.sh`](historical/run.sh) runs it at any commit.

```
docker compose --profile apps run --rm -e MYSQL_HOST=mariadb dev sh bench/historical/run.sh lobsters <commit> spec/races/origin_race_spec.rb
```

| Commit | What it is | Dead Heat |
| --- | --- | --- |
| `7cc3c14ed` | before the fix | broke in **20 of 20** tries: `RecordNotUnique` |
| `8d601f12d` | the fix (`find_or_create_by!`) | broke in **4–5 of 20**: `RecordInvalid` |
| `2ae2f6e1` | next commit, same logic | broke in 4 of 20 |
| `b664dccb` | "fix prod exception on race to create Origin" (April 2025) | **no race in 100 tries** |
| `49c71a6c` | follow-up | no race in 20 tries |

**Why the first fix wasn't enough:** `Origin` also has `validates :identifier, uniqueness: true`. When the
second request arrives just after the first one saved, the validation sees the new row and raises
`RecordInvalid`, which `find_or_create_by!` doesn't catch (it only catches `RecordNotUnique`). Lobsters
hit exactly this in production and fixed it four months later. Dead Heat's *stagger* strategy, which
starts one request a few milliseconds late, finds it from the December commit.

## 2b. Spree: the gift card overspend

[Spree](https://github.com/spree/spree) fixed a "gift card overspend race condition vulnerability" in
March 2026 (`1ce4d2404`). Two orders applying the same gift card at once could both take its whole
balance. Spree's fix came with a spec that starts five threads by hand. The same check as a Dead Heat
race test is [`historical/spree/gift_card_race_spec.rb`](historical/spree/gift_card_race_spec.rb): a
100 card, two orders of 80 each, and the rule "never spend more than the card holds".

```
docker compose run --rm -e DEADHEAT_TRIES=40 dev sh bench/historical/spree/run.sh <commit>
```

| Commit | Dead Heat |
| --- | --- |
| `397173a1` (before the fix) | broke in **40 of 40** tries: the store credits added up to 160 on a 100 card |
| `1ce4d240` (the fix) | **no race in 40 tries** |

Dead Heat's scan, run on the code before the fix with no database, flags the cause:
`gift_card.lock!` outside a transaction, which releases the lock right away.

While setting this up, Dead Heat also found a second, unrelated race in the same service, which is
still in Spree's code. Its details aren't published here.

## 2c. Mastodon: the same post published twice

[Mastodon](https://github.com/mastodon/mastodon) fixed a race "when processing statuses twice with the
same idempotency key" in February 2026 (`cff25c186`). `PostStatusService` read the key from Redis,
published the post, and only then stored the key. A client retrying a post at the same moment published
it twice.

The check lives in Redis, which Dead Heat doesn't restore, so the race test clears Redis before every run
with `r.reset { … }` ([`historical/mastodon/idempotency_race_spec.rb`](historical/mastodon/idempotency_race_spec.rb)).

```
docker compose --profile apps up -d redis
docker compose --profile apps run --rm dev sh bench/historical/run.sh mastodon <commit> spec/races/idempotency_race_spec.rb
```

| Commit | Dead Heat |
| --- | --- |
| `f7bf804a` (before the fix) | broke in **18 of 20** tries: 2 statuses, the account's count up by 2 |
| `cff25c18` (the fix: a Redis lock around the check) | **no race in 40 tries** |

**What Mastodon taught Dead Heat.** Mastodon keeps a Redis connection in `Thread.current` for a thread's
whole life, as apps on Puma may. Dead Heat used to start fresh threads for every run, which stranded one
of those connections per thread until the pool ran dry. It now keeps one long-lived worker thread per
racing request for the whole race, like Puma.

The scan doesn't flag this race: the check is in Redis, not in the database or in Active Record calls it
reads.

## 3. Lobsters: sweeping the whole app with no setup

**Lobsters at `7cc3c14ed`** (MariaDB, 97 request specs pass):
- The sweep checked 19 endpoints in 3 min 13 s and flagged 9.
- Read by hand, **7 were real races**. Two have since been fixed in Lobsters, so they can be named:
  a lost update to the unread-message counter, and a 500 when a tag is created twice. The other five
  are duplicate rows and lost counts in other features.
- The other 2 were differences by design (mod notes are de-duplicated, so two at once write fewer).
- This run also surfaced three mistakes in Dead Heat itself, all fixed:
  - a ranking score that is negative by design counted as "below zero"
  - times written into text were compared as values
  - digits in a username were read as a new row's id

**Lobsters today** (`28bc8d6b`, November 2026: Ruby 4.0, SQLite, 171 request specs pass):
- The sweep checked 25 endpoints in 7 min 37 s.
- Two of the 2024 races are gone: the message counter and the tag 500.
- The others are still in the code. Details of unfixed races aren't published here until Lobsters
  has been told.

## 4. What the pauses add

On a database server (PostgreSQL, MySQL), two tiny test requests started together already overlap, so
the planted Corner Store bugs show up on every try with or without pauses.

On SQLite the database runs inside Ruby's own process, so nothing overlaps unless Dead Heat makes room
for it. Measured with `bench/pauses_bench.rb` (100 tries per row):

| Planted bug (SQLite) | Pauses off | Pauses on |
| --- | --- | --- |
| last item bought twice | 0% | 75% |
| likes counter | 0% | 76% |
| tag check-then-insert | 0% | 77% |
| lost update in a service object | 0% | 75% |

On a real bug on a server database, Lobsters' `RecordInvalid` race at `8d601f12d` (section 2), on
MariaDB, 60 tries each:

| | Pauses off | Pauses on |
| --- | --- | --- |
| Tries that showed the race | **0 of 60** | **11 of 60** |

Without pauses, two requests that start together here never line up the way production traffic
sometimes does. Starting one a few milliseconds later (the stagger strategy) is what exposes it.
