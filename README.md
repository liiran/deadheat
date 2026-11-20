# Dead Heat

**Finds race conditions in Rails apps.**

A race condition is a bug that only shows up when two requests change the same data at the same time.
Each request is correct on its own; together they break it. A store has one shirt left, and two people
press Buy at the same moment:

```
Alice's request: "how many shirts?" → 1     ✓ enough
Bob's request:   "how many shirts?" → 1     ✓ enough
Alice's request: create order, set stock to 0
Bob's request:   create order, set stock to 0
Result: 2 orders for 1 shirt.
```

Nothing crashes, and every test passes, because tests send one request at a time. In production it
happens when someone double-clicks, a phone retries on a bad connection, a payment provider sends the
same webhook twice, or someone sends two requests at once on purpose to use a coupon twice. Then it's a
support ticket that nobody can reproduce.

**Dead Heat makes those collisions happen in your test suite, on purpose and over and over.** It takes
the requests your tests already make and runs each one twice: first one after the other, then at the
same moment. If running them together leaves the database in a state that one after the other never
could, that's a race, and Dead Heat shows you:

- what went wrong, in plain words: "2 orders for 1 shirt"
- both requests' database queries side by side, in the order they ran
- the line of code that caused it, and the standard fix
- a test that fails until it's fixed, so the bug can't come back

**What it covers:** races in data your app keeps in its database, such as stock, balances, counters,
one-use codes, duplicate rows, and a webhook or job processed twice. It doesn't look for thread-safety
bugs in plain Ruby objects or for slowness under load.

**What it is:** a Ruby gem you add to a Rails app's test setup. It runs only in the test environment, on
the test database, on your own computer or in CI.

*In racing, a dead heat is when two runners cross the line at exactly the same moment.*

**When it's useful:**

- A customer was charged twice, or a coupon worked twice, and nobody can reproduce it.
- Before a sale or a launch, to check checkout, credits and limits under double clicks and retries.
- On a pull request that changes a controller, job or webhook handler that writes to the database.
- For webhooks, which payment providers and platforms may deliver more than once.

**Are the races it finds real?** Dead Heat doesn't change your app's code. It only decides when
each request starts, and sometimes makes one wait a few milliseconds after it reads something, a delay a
busy server adds on its own. It reports a race only when the result is one that running the requests
one after the other can't produce. As a check, the demo store's checkout race was reproduced with no
Dead Heat code at all: on a real Puma server, two plain `curl` "Buy" requests sold the last shirt twice
in 20 of 30 tries when sent together, and 3 of 30 when sent 20 ms apart. The fixed version never did
([details](bench/results.md#5-the-same-race-without-dead-heat)).

**Does it work?** [Results](#results) has what was measured, with its limits: known race bugs in
Lobsters, Spree and Mastodon reproduced before their fixes, a sweep of all of Lobsters, and a comparison
with two existing tools.

## What it finds

A race needs two things: a request that **reads** something, decides, and then **writes**, and a second
request that slips in between the read and the write. Almost every race in a web app has one of three
shapes.

### 1. Check, then act

The code checks a condition, then acts on it: *is there stock left? Then sell. Is this coupon unused?
Then apply it. Has this order been paid yet? If not, ship it.*

```ruby
coupon = Coupon.find_by!(code: params[:code])
return render(plain: "Already used", status: :unprocessable_entity) if coupon.used_at

Discount.create!(user: Current.user, coupon: coupon)
coupon.update!(used_at: Time.current)
```

Both requests pass the check before either one marks the coupon used, so both get the discount. The
same shape oversells the last item, takes a gift card or wallet below zero, sells an event past
capacity, and processes a payment webhook twice.

**Fix:** lock the row while deciding (`coupon.with_lock { … }`), or let the database check and change
in one statement: `Coupon.where(id: coupon.id, used_at: nil).update_all(used_at: Time.current) == 1`.

### 2. Read, add in Ruby, save

```ruby
review.update!(helpful_count: review.helpful_count + 1)
```

Both requests read 0, both add one in Ruby, both save 1. Nothing crashes and nothing looks wrong, but one
vote is gone. This is called a *lost update*.

**Fix:** let the database do the arithmetic: `Review.update_counters(review.id, helpful_count: 1)`.

### 3. Look, then create

```ruby
Follow.find_by(user: user, store: store) || Follow.create!(user: user, store: store)
```

Both requests look, find nothing, and both create one. `validates :email, uniqueness: true` is the same
shape hidden inside Rails: it looks for the email, then inserts. If a unique index catches the duplicate,
the second request doesn't make a copy, but it does crash with `RecordNotUnique`, and the user sees an
error page.

**Fix:** a unique index, plus `create_or_find_by!` or a `rescue ActiveRecord::RecordNotUnique`.

### Any of them can send something twice

When the action also sends an email, queues a job or calls an outside service (a payment, a shipment),
the duplicate goes out too. A duplicate row can be deleted, but a sent email or a second charge can't be
taken back, so Dead Heat marks these races **irreversible**.

### How Dead Heat finds them

- **Running the code doesn't need to know the shapes.** The sweep and race tests send requests at the
  same moment and check whether the result could have come from sending them one after the other. That
  catches a race whatever its shape, even when the check isn't in the database (Mastodon's, below, was in
  Redis). They report what they saw: *made twice*, *went below zero*, *lost update*, *crash*, *sent
  twice*, or *different result*.
- **The scan looks for the shapes.** It reads the code without running anything and lists each of the
  three shapes that no lock or unique index protects, plus locks that protect nothing. These are
  suspects, not proof. It takes seconds, and it's the only way to check code that no test reaches.

## Quick start

Dead Heat isn't on RubyGems yet, so add it to your `Gemfile` from this repository:

```ruby
gem "deadheat", github: "liiran/deadheat", group: %i[development test]
```

```bash
bundle install
bin/rails generate deadheat:install
bin/deadheat sweep
```

This is what it prints on the demo store in [`demo/`](demo), on PostgreSQL (shortened where marked `…`;
how many tries out of 20 show a race changes a little from run to run):

```
Dead Heat sweep (Minitest)
Recording the requests your tests make…
Found 23 write requests in 31 tests. Checking 23 endpoints, 20 tries each…

  ✓ POST /fixed/products/:product_id/buy no race found in 20 tries
  ✓ POST /fixed/coupons/:code/redeem   no race found in 20 tries
  …
  ✗ POST /products/:product_id/buy     Made twice: 2 new orders where one at a time there is 1  20/20 tries  [irreversible]
  ✗ POST /coupons/:code/redeem         Made twice: 2 new discounts where one at a time there is 1  17/20 tries
  ✗ POST /wallet/withdraw              Went below zero: wallets #5 balance_cents ended at -3000  18/20 tries
  ✗ POST /reviews/:id/helpful          Lost update: reviews #5 helpful_count went 0 → 1, one at a time 0 → 2  17/20 tries
  …
  ✓ 11 endpoints with no race found
  ~ 2 endpoints with different replies but right data
Checked 23 of the app's 28 write endpoints (82%) using its existing tests, with no setup.
10 races found (2 with side effects that can't be undone) in 1m 20s.
Regression tests written: test/races/sweep/post_products_product_id_buy_race_test.rb, …
Details: bin/deadheat report
```

Then `bin/deadheat report --open` for the details, or `/deadheat` while your app runs in development:

![A finding in the Dead Heat report: both requests read the coupon before either one wrote to it](docs/img/report.png)

## The four commands

| Command | Takes | What it does |
| --- | --- | --- |
| `bin/deadheat sweep` | minutes | Sends each write request your request/integration tests make twice at once. One test per endpoint (`--all` for every request). Writes a regression test for each race. |
| `bin/deadheat scan` | seconds | Reads the code (no database) and lists places that look racy: check-then-act without a lock, arithmetic done in Ruby, look-then-create, uniqueness without an index. Suspects, not findings. |
| `bin/rails test test/races` | seconds | Your race tests, including the ones the sweep wrote. They fail while the race is there. |
| `bin/deadheat report` | instant | The latest results as one HTML page. |

## Race tests

For races between two *different* people (two buyers, one shirt), or code that isn't a request (jobs,
service objects), write a race test. It's a normal test file:

```ruby
require "test_helper"
require "deadheat/minitest"

class CheckoutRaceTest < Deadheat::RaceTest
  race "two buyers, one shirt" do |r|
    r.setup { @shirt = Product.create!(name: "Shirt", stock: 1, price_cents: 2500) }
    r.as(users(:one)) { post "/products/#{@shirt.id}/buy" }
    r.as(users(:two)) { post "/products/#{@shirt.id}/buy" }
    r.check("never sell more than we have") { Order.where(product_id: @shirt.id).count <= 1 }  # optional
  end
end
```

The same request twice, or code that isn't a request at all:

```ruby
race "the payment webhook arrives twice" do |r|
  r.setup { @order = orders(:unpaid) }
  r.twice { post webhooks_order_paid_path, params: { order_id: @order.id } }
end

race "two jobs charge the same order" do |r|
  2.times { r.run { ChargeOrderJob.perform_now(orders(:unpaid).id) } }
end
```

RSpec works the same way with `RSpec.describe "Checkout", type: :race do … end`. `r.as(user)` signs the
user in for that request's own session: Devise and Rails 8's `sign_in_as` work as they are; anything
else is one line in `race_helper.rb`. The `check` is optional: without it, Dead Heat already compares
the data, the replies, the emails and the jobs with every one-at-a-time order. Dead Heat restores the
database before every run. For state it can't see, such as Redis keys or `Rails.cache`, add
`r.reset { Rails.cache.clear }`, or `Deadheat.configure { |c| c.reset { … } }` for every race.

When a race test fails, the message tells the whole story. This is the first test above, run on the demo
store (the timeline is shortened where marked `…`):

```
Race: “two buyers, one shirt” broke in 18 of 20 tries (seed 50484, PostgreSQL 17)

  ✗ Broke the rule “never sell more than we have”  [irreversible] (18 tries)
      orders: 2 new rows (one at a time: 1)
      OrderMailer#confirmation queued 1 more time
      user 298486374 got 302 → /orders/:new (one at a time: 302 → /products/7)

    Why: Both requests read products before either one wrote to it (app/controllers/shop/checkouts_controller.rb:9), so each acted on a value the other was about to change.

    What happened in try 1 (no pauses):
          …
          8.5 ms  user 298486374 │ SELECT "products".* FROM "products" WHERE "products"."id" = 7 LIMIT 1  app/controllers/shop/checkouts_controller.rb:9
          9.2 ms  user 980190962 │ SELECT "products".* FROM "products" WHERE "products"."id" = 7 LIMIT 1  app/controllers/shop/checkouts_controller.rb:9
          …
         14.7 ms  user 980190962 │ INSERT INTO "orders" ("user_id", "product_id", "total_cents", …  app/controllers/shop/checkouts_controller.rb:15
         15.7 ms  user 298486374 │ INSERT INTO "orders" ("user_id", "product_id", "total_cents", …  app/controllers/shop/checkouts_controller.rb:15
          …
         19.6 ms  user 980190962 │ UPDATE "products" SET "stock" = 0, "updated_at" = '2026-11-18 07:21:02.753855' WHERE "products"."id" = 7  app/controllers/shop/checkouts_controller.rb:16
         21.1 ms  user 298486374 │ UPDATE "products" SET "stock" = 0, "updated_at" = '2026-11-18 07:21:02.754908' WHERE "products"."id" = 7  app/controllers/shop/checkouts_controller.rb:16

    Fix:
      • Lock the row while deciding: wrap the read-check-write in `record.with_lock { … }`, so the second request waits and then sees the first one's change.
      • Or let the database check and change in one statement: `Model.where(id: id).where("stock >= ?", n).update_all(["stock = stock - ?", n]) == 1` (it returns 0 when there wasn't enough).

  Reproduce: DEADHEAT_SEED=50484 bin/rails test test/races/checkout_race_test.rb:5
```

Both buyers read "1 left" (lines 8.5 and 9.2 ms) before either one wrote, so both orders went through.

## How it works

**Why running the code finds what reading it misses.** A race isn't in any one line. It's in the timing
between two requests, and tests send one request at a time, so they never see it. Dead Heat makes that
timing happen, then judges the result with one rule that needs no knowledge of your app: *two requests
at once must leave the same result as running them one after the other, in some order.* (Databases call
this being serializable.) Anything else is a race. That's why it needs no list of rules to check, and
why it doesn't flag code that is properly locked: locked code gives a one-at-a-time result.

Nothing here touches database internals. It's ordinary Ruby and Rails:

1. **Racing for real.** Each request runs in its own thread with its own database connection, and they
   start together from a starting line. Ruby lets threads run while one waits on the database, so the
   queries really overlap. The threads live for the whole race and are reused every run, like Puma's,
   so anything an app keeps per thread behaves as it does in production.
2. **Small, targeted pauses.** Starting together isn't always enough. On PostgreSQL and MySQL two small
   requests usually do overlap by themselves, but on SQLite they never do, and some races only show when
   one request arrives just *after* the other. So Dead Heat first watches a one-at-a-time run and finds
   each read that is followed by a write to the same table, like "read the stock, then save the stock".
   The first try has no pauses. Each later try widens that gap a different way:
   - every request waits after that read until the others have made it too
   - whichever request reads first waits a moment
   - one request starts a little later, as the second click of a double click does
   - small random pauses

   The pauses come from a seed, so the same pauses can be run again (`DEADHEAT_SEED=…`).
3. **Comparing with one at a time.** From the same starting data it runs the requests one after
   another in every order, then together. If the together result matches none of the one-at-a-time
   results (rows, replies, errors, emails sent, jobs queued, outside HTTP calls through WebMock), it's
   a race. You don't have to say what "correct" means. New ids, timestamps and random tokens are
   ignored: anything that differs between two identical one-at-a-time runs is noise, not a race.
4. **Exactly the same data every try.** After setup it saves a snapshot, and before each try it puts
   back only the tables that were written. When it's done, every table is exactly as it was.
5. **The sweep** records which requests your tests make and which of them write, then reruns one test
   per endpoint. When that test reaches the request, Dead Heat copies its session (cookies, signed-in
   user), sends the request twice at once, compares, and stops the test.

Dead Heat never says "safe". It says "no race found in 20 tries", because a timing bug can't be proven
absent.

## Results

Everything here can be rerun: the scripts and commands are in [`bench/results.md`](bench/results.md),
which also has the details and the caveats. Timing bugs don't show up the same number of times in every
run, so where a result was measured more than once it's given as a range.

### Known race bugs in real apps, before and after their fixes

Three well-known Rails apps each fixed a race bug. For each one, a short race test was written from the
fix's commit, so **these are reproductions of known bugs, not blind finds**. The question they answer:
does Dead Heat break the code from before the fix, and go quiet on the code after it?

**Lobsters**, the link aggregator: two stories from the same new site at once could crash on a unique
index (shape 3). The race test is ten lines ([`bench/historical/lobsters`](bench/historical/lobsters)).

| Lobsters code | Dead Heat |
| --- | --- |
| `7cc3c14e`, before the fix | broke in **17 of 20** tries (three runs) |
| `8d601f12`, the December 2024 fix | still broke in **1–4 of 20**: the model's uniqueness validation raises `RecordInvalid`, which `find_or_create_by!` doesn't catch |
| `b664dccb`, April 2025, "fix prod exception on race to create Origin" | no race, but the second call now fails even one at a time. Dead Heat says so in a note |
| `49c71a6c`, three days later | **100 of 100** tries match a one-at-a-time run |

Dead Heat finds the gap the December fix left, which Lobsters fixed four months later. One caveat: the
pause that exposes it (starting one request a few milliseconds late) was added to Dead Heat while
studying this bug. Without pauses the gap shows in 0 of 60 tries; with them, in 10 of 60.

**Spree**, the e-commerce platform, fixed a "gift card overspend race condition vulnerability" in March
2026 (shape 1). Two orders using one gift card at once could each take its whole balance.

| Spree code | Dead Heat |
| --- | --- |
| `397173a1`, before the fix | broke in **40 of 40** tries (160 spent from a 100 card) |
| `1ce4d240`, the fix | **40 of 40** tries match a one-at-a-time run |

Dead Heat's scan also points at a cause in the code before the fix: `gift_card.lock!` called outside a
transaction, which releases the lock right away.

**Mastodon** fixed a race in February 2026: a client retrying a post at the same moment published it
twice. Its duplicate check is in Redis, so the race test clears Redis before each run with `r.reset { … }`.

| Mastodon code | Dead Heat |
| --- | --- |
| `f7bf804a`, before the fix | broke in **15–17 of 20** tries (the same post published twice) |
| `cff25c18`, the fix | the duplicate is gone in **40 of 40** tries |

At that fix the retried post fails with an error even one at a time, which Mastodon fixed seven months
later ("Fix submitting a status twice leading to a 500 error"). It isn't a race, so Dead Heat didn't count
it, and at first didn't mention it either. It now prints a note whenever a request fails one at a time.

### Sweeping a whole real app with no setup

The sweep was also run on all of Lobsters, using only its own request specs:

| Lobsters | Write endpoints its specs reach | Time | Flagged | Real, read by hand |
| --- | --- | --- | --- | --- |
| December 2024 (MariaDB) | 17 of 87 (20%) | 3 min 23 s | 9 | 7 |
| Today (Ruby 4.0, SQLite) | 25 of 90 (28%) | 7 to 10 min | 11 | 9 |

Two things to take from this. The sweep only sees what the tests reach, and on a real app that was a
fifth to a quarter of the write endpoints. And not every flag is a bug: some were differences the app
makes on purpose. "Real" is one person's reading of Lobsters' code; Lobsters hasn't been asked. One of
the seven has since been fixed there, and one is a harmless crash for a moderator; those two are named
in [`bench/results.md`](bench/results.md). The rest (today's nine are the same races, reached through
more endpoints), and one more found in Spree, are still in today's code, so they aren't described in
this repository.

### Compared with the tools Rails developers already use

To compare tools side by side, you need an app where you know exactly where every race is. **Corner Store**
([`demo/`](demo)) is that app: a small Rails 8 store built for this benchmark, with ten races planted
on purpose (the shapes above, in features like checkout, coupons and webhooks). Each one has a **fixed
twin**: the same feature with the race fixed. A tool that flags a fixed twin is raising a false alarm.
The app, its tests and Dead Heat were written by the same person, so read this as a demonstration of
what each kind of tool can see, not as an independent benchmark.

Each tool ran on the same code ([`bench/tools_bench.rb`](bench/tools_bench.rb)), on PostgreSQL and MySQL:

| Tool | What it does | Planted races caught | False alarms on the fixed twins |
| --- | --- | --- | --- |
| The app's own tests | Ordinary request tests, one per feature, all passing | 0 of 10 | 0 of 10 |
| [database_consistency](https://github.com/djezzzl/database_consistency) 3.1.2 | Compares models with the database schema | 3 of 10 | 0 of 10 |
| [active_record_doctor](https://github.com/gregnavis/active_record_doctor) 2.1.0 | Compares models with the database schema | 3 of 10 | 0 of 10 |
| Dead Heat scan | Reads the code for the three shapes | 10 of 10 | 0 of 10 |
| **Dead Heat sweep**, tests at their limits | Runs each request twice at once | **10 of 10** | **0 of 10** |
| **Dead Heat sweep**, tests with room to spare | The same | **7 of 10** | **0 of 10** |

What the rows mean:

- **The app's own tests catch nothing, and that's normal.** They aren't broken. Each sends one request
  at a time, the way almost every test suite does, and one request at a time can't race. That's the gap
  Dead Heat fills.
- **The two existing tools catch three.** They ask for a unique index wherever a model says something
  must be unique: the newsletter signup, the store follow, and one shipment per order. Those are the
  three of the ten that a missing unique index explains. The other seven are in controller code, which
  those tools don't read.
- **The sweep finds 10 or 7, depending on the tests.** Three of the races are limits: seats at an event,
  store credit, an invite's uses. The same request sent twice only crosses a limit when the test starts
  right below it. Corner Store's tests do ("the last seat"), which gives 10. Rewritten to leave room
  (100 seats), they give 7, and those three need a race test.
- **The scan's 10 of 10 is the weakest number here.** The same person wrote the planted races and the
  scan's rules, and its zero false alarms are just as fitted. The real apps above are the fairer test of
  the sweep; the scan has no such test yet.
- **SQLite:** the sweep finds 8 (5 with room to spare), and that's correct. Rails 8 lets only one SQLite
  write transaction run at a time, so the two races that depend on a uniqueness validation (newsletter,
  follow) can't happen there.

With the tests at their limits, two of the ten races sent something that can't be taken back: a second
confirmation email and a second shipping job. The sweep reached 23 of this small app's 28 write endpoints
(82%); compare the 20–28% on Lobsters above.

## Safety

**Where it runs.** Dead Heat deletes and restores rows in the tables a race writes to, so it refuses to
run unless all of these are true:

- Rails is in the test environment
- the database's name has "test" in it as a word (`app_test`, `storage/test.sqlite3`,
  `db/test/primary.sqlite3`; not `contest_production`), and doesn't also name another environment
  (`test_scores_production`, `ab_test_development`). In an app with several databases, this goes for
  every one it writes to
- the database doesn't say it was set up for another environment (Rails records this in
  `ar_internal_metadata`)

It also refuses setups that would make its results wrong, and says what to change:

- a connection pool smaller than the number of racing requests + 1
- code reloading turned on
- `allow_concurrency` off
- the test still inside an open transaction
- a test environment that really delivers email (each raced request runs about 25 times)

If you use DatabaseCleaner, it steps aside for race tests and the tests the sweep chooses. When a race
is over, every table is back as it was, and the database connections have their usual settings.

**What it adds to your app.** One route, `/__deadheat/ping`, in the test environment only. It answers
with an empty 204 and does nothing else; Dead Heat uses it to sign test users in through Devise. The
`/deadheat` dashboard is mounted by the installer for development only. It answers only requests from
your own computer, only in development and test, and only reads the results folder. Nothing is added in
production.

Three things to know about the dashboard:

- A development server inside a container sees your browser as another computer and answers 403.
  `DEADHEAT_DASHBOARD_ALLOW_REMOTE=1` drops the "from this computer" check there. The page must still
  be asked for by a local name (`localhost`) or one your app accepts in `config.hosts`, and a script
  on another website still can't read it. Anyone who can reach that port can, though, so publish the
  port to your own computer only (`127.0.0.1:3000:3000`).
- A tunnel or port forward that adds no headers makes outside visitors look local, so don't put a
  development server that mounts the dashboard on the internet.
- `bin/deadheat report` gives the same page as a file, with no server at all.

**What it writes, and where.** Everything stays on your computer. Dead Heat doesn't send anything
anywhere and has no network code.

- `tmp/deadheat/`: results as JSON, the test logs of a sweep, and `report.html`. The installer adds this
  folder to `.gitignore`. Only the 30 newest runs are kept.
- `test/races/sweep/` (or `spec/races/sweep/`): one regression test for each race a sweep finds. It
  never overwrites a file that's already there.

The results hold what's needed to explain a race: the SQL the racing requests sent (with values, cut
short), the rows that differed, reply statuses and redirects, email recipients and subjects, job names
and arguments, and the addresses of outside HTTP calls. Request bodies, cookies and headers aren't
stored. Columns your app already hides from its logs with `config.filter_parameters` (passwords, tokens,
and in new Rails apps emails) show as `[FILTERED]`. That goes by column name and is a best effort, like
the log filter it follows: a secret in a column you don't filter, or inside a URL, is shown as it is. It's
test data, but treat the folder like `log/test.log` if your tests use real data.

## Limits

What the sweep can and can't see:

- **Request and integration tests only.** Controller tests and browser (system) tests aren't swept.
- **Only what your tests reach.** The sweep checks the endpoints your tests call, and the coverage line
  says how many that is. On a large app it can be a small share (see [`bench/results.md`](bench/results.md)).
- **Only requests that write to the database.** A request that only sends an email or calls another
  service isn't swept.
- **The same request twice.** That finds double clicks, retries and repeated webhooks. A race between
  two *different* requests needs a race test.
- **Limits only at the limit.** "100 seats", "5 uses": two requests at once cross a limit only when the
  test starts right below it (the last seat). From a test with room to spare, the sweep can't see that
  race. The scan still points at the code, and a race test settles it.

What Dead Heat compares and restores:

- **The main database.** In an app with several databases (`connects_to`), writes to the others aren't
  restored or compared; Dead Heat says so when it sees one.
- **Database rows, replies, emails, jobs and outside HTTP calls** (through WebMock). Not the return
  values of `r.run` blocks, not files, and not Redis or `Rails.cache` unless you reset them with
  `r.reset`.
- **Not the `sessions` table** or other tables Rails and common gems keep for themselves.
- **"Irreversible" is a judgement by name.** A duplicate email, a duplicate outside POST, or a duplicate
  job whose name suggests money, shipping or a message (`ShipOrderJob`, `ChargeJob`) gets the label.

Running it:

- **Threads, not processes.** Races between separate processes (several Puma workers sharing an
  in-memory cache) aren't modeled.
- **Each raced request runs about 25 times.** Anything it does outside the database happens that many
  times, so stub outside services in tests, as most suites already do. Dead Heat refuses to run when the
  test environment really delivers email.
- **Made for test databases.** It reads every table into memory when a race starts, and the tables the
  race wrote after each try, to compare and restore them. That's quick for test data and slow for a
  test database seeded with millions of rows.
- **PostgreSQL:** restoring rows needs a database user that may switch off foreign-key triggers (a
  superuser), the same as Rails' own fixtures.
- **SQLite:** supported. Rails 8 lets one SQLite write transaction run at a time, so fewer races are
  possible there, and Dead Heat reports what really happens.
- **If a run is killed hard** (`kill -9`, power loss) while a race is going, its rows can stay in the
  test database. `bin/rails db:test:prepare` resets it. Ctrl-C is fine.
- **"Broke in 18 of 20 tries" isn't how often it happens in production.** Dead Heat picks the timings
  most likely to collide, so the count says how reliably the test shows the bug, not how often real
  traffic would hit it. That depends on how far apart real requests arrive and how long the gap between
  the read and the write is ([`bench/results.md`](bench/results.md#5-the-same-race-without-dead-heat)
  has an example).
- **Some findings need a person to judge.** Dead Heat shows exactly what differed. A "different result"
  can be on purpose: an app that de-duplicates log entries writes fewer of them when two requests arrive
  together. And the scan only lists suspects: it looks inside one method at a time and knows a fixed set
  of safe idioms.

## Requirements

- Ruby 3.2 or newer (tested on 3.4 and 4.0)
- Rails 7.1 to 8.1
- PostgreSQL, MySQL, MariaDB or SQLite
- Minitest or RSpec

There's no CI yet. "Tested" means the commands below were run by hand on every combination: the gem's
tests on Rails 7.1, 7.2, 8.0 and 8.1, each on SQLite, PostgreSQL and MySQL, and on Ruby 4.0.

## Developing Dead Heat

Everything runs in Docker, so it works the same on Windows, macOS and Linux:

```bash
docker compose run --rm dev bundle install
docker compose run --rm dev bundle exec rake test             # SQLite, PostgreSQL and MySQL
docker compose run --rm dev bundle exec rake test:sweep       # sweep Corner Store end to end
docker compose run --rm -e DB=postgres dev ruby bench/tools_bench.rb
```

The demo app in `demo/` has its own Gemfile. `rake test:sweep` installs its gems the first time; to use
the demo or the benchmarks directly, run `docker compose run --rm dev bundle exec rake demo:bundle` once.

`BUNDLE_GEMFILE=gemfiles/rails_7_1.gemfile` (or 7_2, 8_0, 8_1) runs the tests against another Rails, and
`docker compose --profile ruby4 run --rm dev4 …` against Ruby 4.

Where the ideas come from:
- *Feral Concurrency Control* (Bailis et al., SIGMOD 2015) showed that most Rails apps check invariants in
  code rather than in the database.
- *ACIDRain* (Warszawski and Bailis, SIGMOD 2017) found these bugs in real e-commerce apps.
- Randomized scheduling (Burckhardt et al., ASPLOS 2010) showed that a few randomly placed delays find
  ordering bugs with a provable chance on every run.
