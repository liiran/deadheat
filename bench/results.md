# Results

Every table here comes from a script in this folder, and each section gives the command. All of it was
rerun on the code as committed. Timing bugs don't show the same number of times in every run, so where
a result was measured in more than one run it's given as a range.

Runs were on a Windows 11 desktop (Ryzen 5 9600X) with everything in Docker: Ruby 3.4 (Ruby 4.0 for
today's Lobsters), Rails 8.1, PostgreSQL 17, MySQL 8.4, MariaDB 11.4 and SQLite 3.

**Who wrote what.** Dead Heat, the Corner Store demo and its tests, and the race tests for the real apps
were all written by the same person. Sections 2 and 3 use other people's code and other people's bugs;
section 1 doesn't, and should be read as a demonstration.

**Rerunning sections 2 and 3.** They need each app's code in `bench/apps/` (which git ignores):

```
git clone https://github.com/lobsters/lobsters bench/apps/lobsters
git clone https://github.com/spree/spree bench/apps/spree
git clone https://github.com/mastodon/mastodon bench/apps/mastodon
```

The commands below then install and run those projects' code, at old commits, inside the `dev`
container, which can write to this folder. Run them where you would be happy to run those projects.

How to read a race test's result (`bench/historical/summary.rb` prints it):

- **ok:** the try gave exactly the result of running the two requests one after the other
- **race / crash:** the try broke
- **differs:** the data was right, but the replies matched no one-at-a-time run. Not counted as a race.
- **a note:** printed when a request fails even one at a time, because "no race" then only means that
  two at once did no worse

## 1. Corner Store: Dead Heat next to the tools Rails developers already use

To compare tools you need an app where you know exactly where every race is, so
[`demo/`](../demo) was built for this: a small Rails 8 store with ten races planted on purpose in
realistic features (checkout, coupons, gift cards, webhooks…). Each feature has:

- a **fixed twin**: the same feature with the race fixed. A tool that flags it is raising a false alarm.
- an **ordinary test**, the kind any app has. All 32 of the app's tests pass, even though ten features
  are broken, because each test sends one request at a time.

The tools:

- **The app's own tests:** the 32 ordinary tests.
- **database_consistency 3.1.2** and **active_record_doctor 2.1.0:** popular gems that compare an app's
  models with its database schema, for example "this model validates that emails are unique, but the
  table has no unique index on email". Both ran with their default settings.
- **Dead Heat scan:** reads the code, without running it, for the shapes races take (see the README).
- **Dead Heat sweep:** runs each request from the tests twice at the same moment and compares the
  result with running it twice one after the other.

```
docker compose run --rm -e DB=postgres dev ruby bench/tools_bench.rb     # or DB=mysql, DB=sqlite
```

Planted races caught, out of 10:

| Tool | PostgreSQL | MySQL | SQLite | Alarms on fixed twins |
| --- | --- | --- | --- | --- |
| The app's own tests | 0 | 0 | 0 | 0 |
| database_consistency 3.1.2 | 3 | 3 | 3 | 0 |
| active_record_doctor 2.1.0 | 3 | 3 | 3 | 0 |
| Dead Heat scan | 10 | 10 | 10 | 0 |
| **Dead Heat sweep**, tests at their limits | **10** | **10** | **8** | **0** |
| **Dead Heat sweep**, tests with room to spare | **7** | **7** | **5** | **0** |

- **How a race counts as caught** is written at the top of the script. For the two schema tools it's a
  message asking for a unique index on one of the feature's tables, which is the only advice either one
  gives that is about races. Everything each tool printed is saved in `bench/out/`.
- **The app's own tests: 0.** Not because they're broken: one request at a time can't race.
- **The two schema tools: 3.** They flag the three races a missing unique index explains: the newsletter
  signup and the store follow (a uniqueness validation with no index) and the shipment (`has_one` with no
  index). The other seven are in controller code, which they don't read. An earlier version of the demo
  left two of those model lines out, and the tools scored 1; the models now say what a normal app's would.
- **The sweep: 10 with the tests as written, 7 with room to spare.** Five features have a limit (stock,
  a card's balance, seats, store credit, an invite's uses), and the demo's tests sit right at it: the
  last shirt, the last seat. `ROOM=1` gives every limit room instead (5 in stock, 100 seats, a small
  withdrawal). Then the sweep still finds stock and the gift card, because those lose an update whatever
  the amount. It no longer finds seats, store credit and invites: the same request sent twice below a
  limit gives the same result together as one after the other. Those need a race test, or a test that
  starts at the limit. The scan flags all three.
- **SQLite: 8 (5) is the right answer.** Rails 8 starts each SQLite write transaction with
  `BEGIN IMMEDIATE`, which takes the database's write lock straight away, so a second signup or follow
  waits until the first has finished and its uniqueness validation then sees the row. Those two races
  can't happen there. The follow shows up as a note instead: the second request gets a 422.
- **The scan's 10 of 10, and its 0 alarms, should be read with care:** the planted races, the fixed
  twins and the scan's rules were written by the same person. The scan looks inside one method at a time
  and knows a fixed set of safe idioms. On Mastodon it listed 127 suspects, which nobody has gone through.
- **Irreversible:** with the tests at their limits, two of the ten races sent something that can't be
  taken back: a second order confirmation email (a queued `OrderMailer` job) and a second
  `ShipOrderJob`. The label goes by the kind of side effect and, for jobs, by the job's name.
- **Coverage:** the sweep reached 23 of the app's 28 write endpoints (82%) from its existing tests. That's
  a small app with a test for nearly every feature; section 3 has the numbers for a real one.

## 2. Known race bugs in real apps, before and after their fixes

Each race test here was written from the upstream fix: it sets up the situation the fix's commit
describes and sends the two calls. So these are reproductions of known bugs. The scripts check the app
out at a commit (cloned into `bench/apps/`, which isn't committed), add Dead Heat, and run the race test.

### 2a. Lobsters: the origin race

[Lobsters](https://github.com/lobsters/lobsters) had a race in `Domain#find_or_create_origin`: two
stories from the same new site at once could both insert the same origin, and the unique index stopped
the second with an unhandled `ActiveRecord::RecordNotUnique`. Lobsters' own draft spec for it is in
`7cc3c14e`. The race test is ten lines
([`historical/lobsters/origin_race_spec.rb`](historical/lobsters/origin_race_spec.rb)).

```
docker compose --profile apps up -d mariadb
docker compose --profile apps run --rm -e MYSQL_HOST=mariadb -e DEADHEAT_TRIES=20 dev sh bench/historical/run.sh lobsters <commit> spec/races/origin_race_spec.rb
```

| Commit | What it is | Dead Heat |
| --- | --- | --- |
| `7cc3c14e` | before the fix | broke in **17 of 20** tries, in each of three runs |
| `8d601f12` | December 2024: the fix (`find_or_create_by!`) | broke in **1–4 of 20** (three runs: 3, 1, 4) |
| `b664dccb` | April 2025: "fix prod exception on race to create Origin" (`create_or_find_by!`) | no race in 100 tries, with a note: the second call fails with `RecordInvalid` even one at a time. 87 tries "differ" (two at once both finish), 13 are ok |
| `49c71a6c` | three days later: "fix duplication exception by not raising?" | **100 of 100** tries ok |

**Why the December fix wasn't enough:** `Origin` also has `validates :identifier, uniqueness: true`. When
the second request arrives just after the first one saved, the validation sees the new row and raises
`RecordInvalid`, which `find_or_create_by!` doesn't rescue (it rescues `RecordNotUnique`).

**What this does and doesn't show.** Dead Heat reproduces the gap the December fix left, which Lobsters
fixed four months later. It isn't a prediction: the *stagger* pause that exposes it (one request starts
a few milliseconds late) was added to Dead Heat while studying this bug. Section 4 has the numbers with
pauses off. And at `b664dccb` Dead Heat's first version reported a plain "no race" for a method whose
second call always failed; the note was added because of that.

### 2b. Spree: the gift card overspend

[Spree](https://github.com/spree/spree) fixed a "gift card overspend race condition vulnerability" in
March 2026 (`1ce4d2404`). Two orders applying the same gift card at once could both take its whole
balance. Spree's fix came with a spec that starts five threads by hand; the same check as a Dead Heat
race test is [`historical/spree/gift_card_race_spec.rb`](historical/spree/gift_card_race_spec.rb): a
100 card, two orders of 80 each, and the rule "never spend more than the card holds".

```
docker compose run --rm -e DEADHEAT_TRIES=40 dev sh bench/historical/spree/run.sh <commit>
```

| Commit | Dead Heat |
| --- | --- |
| `397173a1` (before the fix) | broke in **40 of 40** tries: the store credits added up to 160 on a 100 card |
| `1ce4d240` (the fix) | **40 of 40** tries ok |

Dead Heat's scan, run on `app/services/spree/gift_cards/apply.rb` from before the fix with no database,
flags one cause: `gift_card.lock!` outside a transaction, which releases the lock right away. On the
fixed file that suspect is gone.

While setting this up, Dead Heat also found a second, unrelated race that is still in Spree's code.
It isn't described here.

### 2c. Mastodon: the same post published twice

[Mastodon](https://github.com/mastodon/mastodon) fixed a race "when processing statuses twice with the
same idempotency key" in February 2026 (`cff25c186`). `PostStatusService` read the key from Redis,
published the post, and only then stored the key. A client retrying a post at the same moment published
it twice.

The check lives in Redis, which Dead Heat doesn't restore, so the race test clears Redis before every run
with `r.reset { … }` ([`historical/mastodon/idempotency_race_spec.rb`](historical/mastodon/idempotency_race_spec.rb)).

```
docker compose --profile apps up -d redis
docker compose --profile apps run --rm -e DEADHEAT_TRIES=20 dev sh bench/historical/run.sh mastodon <commit> spec/races/idempotency_race_spec.rb
```

| Commit | Dead Heat |
| --- | --- |
| `f7bf804a` (before the fix) | broke in **15–17 of 20** tries (three runs): 2 statuses, the account's count up by 2 |
| `cff25c18` (the fix: a Redis lock around the check) | **40 of 40** tries ok: the duplicate is gone |

**A note on that fix.** At `cff25c18` the second post fails with `NoMethodError` even one at a time (each
call uses a new `PostStatusService`, as a request does). Mastodon fixed "submitting a status twice
leading to a 500 error" seven months later (`4e15f3db`, September 2026). It isn't a race, so Dead Heat
didn't count it; its first version didn't mention it either, and it now prints a note. That later commit
wasn't run here: it needs a newer Ruby than this setup could build its gems for.

**What Mastodon taught Dead Heat.** Mastodon keeps a Redis connection in `Thread.current` for a thread's
whole life, as apps on Puma may. Dead Heat used to start fresh threads for every run, which stranded one
of those connections per thread until the pool ran dry. It now keeps one long-lived worker thread per
racing request for the whole race, like Puma.

The scan doesn't flag this race: the check is in Redis, not in the database or in Active Record calls it
reads.

## 3. Lobsters: sweeping a whole app with no setup

No race test here: the sweep takes the requests Lobsters' own request specs make and sends each one
twice.

```
docker compose --profile apps run --rm -e MYSQL_HOST=mariadb dev sh bench/historical/run.sh lobsters 7cc3c14ed sweep
docker compose --profile ruby4 run --rm dev4 sh bench/historical/run.sh lobsters 28bc8d6b sweep
```

| | December 2024 (`7cc3c14e`, MariaDB) | Today (`28bc8d6b`, November 2026, Ruby 4.0, SQLite) |
| --- | --- | --- |
| Request specs, all passing | 97 | 171 |
| Requests they make, and how many of those write | 153, 89 | 260, 136 |
| Write endpoints the sweep reached | **17 of 87 (20%)** | **25 of 90 (28%)** |
| Requests raced (one per method and route) | 19 | 29 |
| Time | 3 min 23 s | 7 to 10 min (10 with other benchmarks running) |
| Flagged as a race or a crash | 9 | 11 |
| Notes: right data, different replies | 4 | 6 |
| Clean | 6 | 12 |
| Flagged and real, read by hand | 7 | 9 |
| Flagged, but a difference the app makes on purpose | 2 | 2 |

- **Coverage is the limit.** The sweep reaches only the write endpoints the request specs call: about a
  fifth to a quarter of Lobsters'. The origin race of section 2a isn't among them (no request spec posts
  a story), so the sweep alone would not have found it.
- **Flagged isn't the same as real.** Each flag was read against Lobsters' code by one person. In 2024,
  7 of the 9 were real races and 2 were differences the app makes on purpose (mod notes are
  de-duplicated, so two at once write fewer). Lobsters hasn't been asked to confirm any of them.
- **Two of the seven can be named.** A lost update to the unread-message counter has since been
  fixed in Lobsters. A 500 when a moderator creates the same tag twice at once did not show up in
  today's run, but that run was on SQLite, where this kind of race can't happen (one write
  transaction at a time); the code looks unchanged, so on MariaDB it is probably still there. It
  only shows an error page to a moderator who double-submits, and the data stays correct.
- **The other five are still in today's code,** so they aren't described here or anywhere in this
  repository. Today's nine are those same races, reached through more endpoints.
- **This run also surfaced mistakes in Dead Heat itself,** all fixed:
  - a ranking score that is negative by design counted as "below zero"
  - times written into text were compared as values
  - digits in a username were read as a new row's id
  - SQLite's own bookkeeping table was compared as data

## 4. What the pauses add

`bench/pauses_bench.rb` runs six small planted bugs from the gem's own test app (`test/dummy`, not Corner
Store) 100 times each, with pauses off and on. With pauses off the two requests still start together
from the same starting line; only the pauses are missing.

```
docker compose run --rm -e DB=sqlite dev bundle exec ruby bench/pauses_bench.rb     # or DB=postgres, DB=mysql
```

Tries that showed the bug, out of 100:

| Planted bug | SQLite, off | SQLite, on | PostgreSQL, off | PostgreSQL, on | MySQL, off | MySQL, on |
| --- | --- | --- | --- | --- | --- | --- |
| last item bought twice | 0 | 72 | 100 | 91 | 100 | 93 |
| likes counter | 0 | 73 | 100 | 87 | 100 | 86 |
| signup without a unique index | 0 | 0 | 99 | 83 | 100 | 83 |
| follow that hits a unique index | 0 | 0 | 100 | 83 | 99 | 83 |
| tag check-then-insert | 0 | 75 | 100 | 87 | 100 | 85 |
| lost update in a service object | 0 | 73 | 100 | 89 | 100 | 84 |

- **SQLite:** the database runs inside Ruby's own process, so nothing overlaps unless Dead Heat makes
  room for it. With pauses, about three tries in four show the bug. The two rows that stay at 0 can't
  race on SQLite with Rails 8 at all (section 1 explains why).
- **PostgreSQL and MySQL:** these small bugs show on nearly every try with no pauses, and pauses make
  that slightly *worse*. About one try in six starts one request late on purpose, and for a simple bug
  that try misses. So on a server database the pauses didn't help with any of these six.

On a real bug on a server database, Lobsters' `RecordInvalid` race at `8d601f12` (section 2a), on
MariaDB, 60 tries each (`-e DEADHEAT_PAUSES=0` turns them off):

| | Pauses off | Pauses on |
| --- | --- | --- |
| Tries that showed the race | **0 of 60** | **10 of 60** |

Without pauses, two requests that start together here never line up the way production traffic
sometimes does. Starting one a few milliseconds later (the stagger strategy, one try in six) is what
exposes it. As section 2a says, that strategy was built on this bug, so this table shows that the pause
works on the case it was made for, not that it generalizes.

## 5. The same race without Dead Heat

Dead Heat starts requests together and sometimes makes one wait a few milliseconds. So, does what it
finds also happen with none of that? `bench/double_click.sh` runs the demo on a real Puma server (2
worker processes, 3 threads each), signs one shopper in, and uses plain `curl` to press "Buy" twice on
a product with 1 in stock, with a gap between the two presses. No Dead Heat code is involved. 30
products per row:

```
docker compose run --rm dev sh bench/double_click.sh                # PostgreSQL
docker compose run --rm -e DB=sqlite dev sh bench/double_click.sh
```

| Gap between the two presses | Racy checkout, PostgreSQL | Racy checkout, SQLite | Fixed twin, both |
| --- | --- | --- | --- |
| 0 ms (sent together) | sold twice 20 of 30 | 18 of 30 | 0 of 30 |
| 5 ms | 22 of 30 | 19 of 30 | 0 of 30 |
| 20 ms | 3 of 30 | 2 of 30 | 0 of 30 |
| 100 ms | 0 of 30 | 0 of 30 | 0 of 30 |

- **The race is real:** a real server, sent two real requests, sells the last shirt twice. The fixed
  version never does.
- **The gap is what matters.** This checkout takes a few milliseconds between reading the stock and
  saving it, so only presses closer together than that collide. A person's double click (often 100 ms
  or more apart) rarely would here. Two requests sent at once (a retry, a script, someone trying it on
  purpose) often do. A real checkout that calls a payment provider between the check and the save holds
  the gap open for hundreds of milliseconds, and then ordinary double clicks hit it too.
- **This is why Dead Heat makes the timing happen** instead of waiting for it. The pauses don't change
  what the code does; they choose a timing, of the kind shown in the first two rows, that a server can
  hit on its own.
