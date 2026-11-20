#!/bin/sh
# Does the demo's checkout race happen with no Dead Heat code at all? A real Puma server (2 worker
# processes x 3 threads), one signed-in shopper, and curl pressing "Buy" twice, with a gap of 0, 5,
# 20 or 100 ms between the two presses. Every product starts with 1 in stock. Both the racy checkout
# (/products/:id/buy) and its fixed twin (/fixed/products/:id/buy) are tried.
#
#   docker compose run --rm dev sh bench/double_click.sh             # PostgreSQL
#   docker compose run --rm -e DB=sqlite dev sh bench/double_click.sh
#
# It recreates the demo's development database.
set -e
cd /deadheat/demo
export DB=${DB:-postgres} RAILS_ENV=development
ROUNDS=${ROUNDS:-30}
bin/rails db:drop db:create db:schema:load >/dev/null 2>&1
bin/rails runner "
  User.create!(email_address: 'buyer@example.com', password: 'correct horse')
  (1..$ROUNDS*8).each { |i| Product.create!(name: \"Shirt #{i}\", price_cents: 1500, stock: 1) }
" >/dev/null
bundle exec puma -q -w 2 -t 3:3 -b tcp://127.0.0.1:3999 >/tmp/puma.log 2>&1 &
PUMA=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:3999/ && break; sleep 0.5; done

J=/tmp/jar
rm -f $J /tmp/codes
token() { curl -s -b $J -c $J "http://127.0.0.1:3999$1" | sed -n 's/.*name="csrf-token" content="\([^"]*\)".*/\1/p'; }
T=$(token /session/new)
curl -s -o /dev/null -b $J -c $J -X POST http://127.0.0.1:3999/session \
  --data-urlencode "authenticity_token=$T" --data-urlencode "email_address=buyer@example.com" \
  --data-urlencode "password=correct horse"

buy() { # $1 = /shop path or /fixed path prefix, $2 = product id
  curl -s -o /dev/null -w "%{http_code}" -b $J -H "X-CSRF-Token: $T" -X POST "http://127.0.0.1:3999$1/products/$2/buy"
}
T=$(token /session/new)
[ -n "$T" ] || { echo "no CSRF token"; exit 1; }
id=0
for prefix in "" /fixed; do
  for gap in 0 0.005 0.02 0.1; do
    first=$((id + 1))
    for r in $(seq 1 "$ROUNDS"); do
      id=$((id + 1))
      buy "$prefix" $id >>/tmp/codes & a=$!
      [ "$gap" = 0 ] || sleep "$gap"
      buy "$prefix" $id >>/tmp/codes & b=$!
      wait $a $b
    done
    echo "${prefix:-/shop (racy)} gap=${gap}s products=$first..$id"
  done
done
echo "reply codes: $(fold -w3 /tmp/codes | sort | uniq -c | tr -s ' 
' ' ')"
kill $PUMA; wait $PUMA 2>/dev/null || true
bin/rails runner "
  per = $ROUNDS
  Product.order(:id).each_slice(per).with_index do |products, i|
    two = products.count { |p| Order.where(product: p).count > 1 }
    neg = products.count { |p| p.stock < 0 }
    label = (i < 4 ? 'racy ' : 'fixed') + ' gap ' + %w[0ms 5ms 20ms 100ms][i % 4]
    puts \"#{label}: #{two} of #{per} products sold twice, #{neg} with stock below 0\"
  end
"
