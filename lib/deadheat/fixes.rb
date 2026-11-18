# frozen_string_literal: true

module Deadheat
  # The standard ways to fix each kind of race, in plain Rails.
  module Fixes
    LOCK = "Lock the row while deciding: wrap the read-check-write in `record.with_lock { … }`, so the second request waits and then sees the first one's change."
    CONDITIONAL = "Or let the database check and change in one statement: `Model.where(id: id).where(\"stock >= ?\", n).update_all([\"stock = stock - ?\", n]) == 1` (it returns 0 when there wasn't enough)."
    COUNTER = "Let the database do the arithmetic: `Model.update_counters(id, column: 1)` or `update_all(\"column = column + 1\")` instead of reading, adding in Ruby and saving."
    UNIQUE = "Add a unique index on the columns that must be unique (a model `validates uniqueness` can't stop two requests at once), then handle the conflict: `Model.create_or_find_by(…)` or `rescue ActiveRecord::RecordNotUnique`."
    IDEMPOTENT = "For repeated submissions (double clicks, retries, webhooks delivered twice), accept an idempotency key and store it with a unique index; a repeat then finds the first result instead of doing the work again."
    HANDLE_UNIQUE = "The database already stopped the duplicate, but the request crashed. Rescue `ActiveRecord::RecordNotUnique` (or use `create_or_find_by`) and reply as if the first request won."
    VALIDATION_RACE = "A uniqueness validation saw the other request's row and raised `ActiveRecord::RecordInvalid`, which `find_or_create_by!`/`create_or_find_by!` don't catch (they only catch `RecordNotUnique`). Let the unique index decide: drop the `validates … uniqueness` check for this path, or rescue `RecordInvalid` and look the row up again."
    SQLITE_BUSY = "SQLite let both requests start reading, then couldn't let both write (\"database is locked\"). Before Rails 8, SQLite transactions start DEFERRED; Rails 8 starts them IMMEDIATE, which makes the second writer wait instead of failing. Upgrade, or use IMMEDIATE transactions and a busy timeout."
    DEADLOCK = "The database broke a deadlock by failing one request. Take row locks in the same order everywhere, or retry the transaction once on `ActiveRecord::Deadlocked`."
    LOCK_TIMEOUT = "One request waited too long for a lock. Keep transactions short, and don't make outside calls while holding a row lock."
    SIDE_EFFECT = "Send the email, job or outside call only when this request actually changed the state: do it after the guarded update succeeds (or in `after_commit`), and record that it was sent under a unique index."

    module_function

    def for(kind, error: nil)
      case kind
      when :below_zero, :check then [LOCK, CONDITIONAL]
      when :lost_update then [COUNTER, LOCK]
      when :made_twice, :duplicate_rule then [UNIQUE, IDEMPOTENT]
      when :sent_twice then [SIDE_EFFECT, LOCK]
      when :misleading_reply then [CONDITIONAL, LOCK]
      when :crash
        case error.to_s
        when /RecordNotUnique/ then [HANDLE_UNIQUE]
        when /RecordInvalid/ then [VALIDATION_RACE, HANDLE_UNIQUE]
        when /database is locked|BusyException/i then [SQLITE_BUSY]
        when /Deadlock/ then [DEADLOCK]
        when /LockWaitTimeout|LockTimeout/ then [LOCK_TIMEOUT]
        else [LOCK]
        end
      else [LOCK, UNIQUE]
      end
    end
  end
end
