# Security

## Reporting a problem

If you find a way Dead Heat could harm an app, leak data, or be reached by someone it shouldn't be,
please report it privately: on this repository's **Security** tab, choose **Report a vulnerability**.
Please don't open a public issue for it.

A good report says what you ran, what you expected and what happened. A small app or test that shows
it is the fastest way to a fix.

## What to expect from Dead Heat

The [Safety section of the README](README.md#safety) says exactly what Dead Heat does to your app.
In short:

- It runs only in the test environment, against a database that is clearly a test database, and
  refuses otherwise.
- It changes rows only in that test database, and puts every table back when a race is over.
- It writes files only under `tmp/deadheat/` and `test/races/` (or `spec/races/`). The installer also
  adds `bin/deadheat`, one line to `config/routes.rb` and one to `.gitignore`.
- It makes no network connections and sends nothing anywhere.
- Its dashboard answers only in development and test, only to your own computer, and not to
  scripts on other websites.
- Columns and parameters your app hides from its logs (`config.filter_parameters`) are hidden in
  Dead Heat's output too. This goes by name. A secret in a column your app doesn't filter, in the
  path of a URL (`/password_resets/<token>`) or in an email's subject is shown as it is, so treat
  result files like test logs: don't publish them if your test data is sensitive.

Anything that breaks one of these is a security bug, and worth reporting.

## The demo app

`demo/` is a small store with ten race conditions in it **on purpose**. It is there to be tested, not
deployed. Bugs under `demo/app/controllers/shop/` are the point, not a vulnerability.

## Dependencies

Dead Heat depends on Rails itself, `concurrent-ruby` and `prism`. It supports Rails 7.1 to 8.1; use
a Rails version that still gets security fixes.
