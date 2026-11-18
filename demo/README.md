# Corner Store

A small Rails 8 store that exists to show [Dead Heat](../README.md) at work and to measure it.

**It has ten race conditions in it on purpose. Don't deploy it or copy code from `app/controllers/shop/`.**
It has no production database configured, so it can't be started in production by accident.

## What's in it

Ten ordinary features, each written twice:

- `app/controllers/shop/` has the version with the race (routes like `POST /coupons/:code/redeem`)
- `app/controllers/fixed/` has the same feature with the race fixed (the same routes under `/fixed`)

Every feature has one ordinary test (`test/integration/store_features.rb`, run against both versions).
All of them pass: with one request at a time, every feature works.

| # | Feature | What goes wrong when two requests arrive at once | How the fixed version stops it |
| --- | --- | --- | --- |
| 1 | Buy the last item | Both buyers see "1 left": two orders, two confirmation emails | Locks the product row while deciding |
| 2 | One-use coupon | Both requests see it unused: two discounts | Marks it used and checks in one statement |
| 3 | Pay with a gift card | Both see the full balance: more is spent than the card holds | Locks the card while checking and charging |
| 4 | Newsletter signup | The uniqueness validation passes twice: the same email is stored twice | A unique index, and the conflict is handled |
| 5 | "Was this review helpful?" | Both add one to the same number: one vote is lost | The database adds one |
| 6 | "Order paid" webhook | Both see it unpaid: the order ships twice | Marks it paid and checks in one statement, plus a unique index |
| 7 | Follow a store | Both find no follow: the follow is stored twice | A unique index and `create_or_find_by!` |
| 8 | Event tickets | Both count the seats sold: more tickets than seats | Locks the event while counting and selling |
| 9 | Withdraw store credit | Both see enough credit: the balance goes below zero | The database only takes the credit if it's there |
| 10 | Invite code | Both see uses left: the code is used too many times | Locks the invite while checking and using it |

## Running it

From the repository's root folder (everything runs in Docker):

```bash
docker compose run --rm -w /deadheat/demo dev bin/rails db:prepare
docker compose run --rm -w /deadheat/demo dev bin/rails test       # the ordinary tests: all pass
docker compose run --rm -w /deadheat/demo dev bin/deadheat scan    # reads the code
docker compose run --rm -w /deadheat/demo dev bin/deadheat sweep   # sends each request twice at once
docker compose run --rm -w /deadheat/demo dev bin/deadheat report  # writes tmp/deadheat/report.html
```

Add `-e DB=postgres` or `-e DB=mysql` after `run --rm` to use one of those instead of SQLite.

The sweep finds the ten races under `/` and none under `/fixed`. On SQLite it finds nine: Rails 8 lets
only one SQLite write transaction run at a time, so the newsletter race (number 4) can't happen there.

The same tests exist as RSpec request specs in `spec/requests/` (`bin/deadheat sweep --rspec`).

The numbers in the main README come from [`bench/tools_bench.rb`](../bench/tools_bench.rb), which runs
this app's tests, two other tools and Dead Heat on this code.
