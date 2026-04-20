INSERT INTO customers (email, country_code)
VALUES ('alice@example.com', 'DE');

INSERT INTO orders (customer_id, amount_cents, status)
VALUES
  (1, 1999, 'paid'),
  (1, 4999, 'paid'),
  (1, 2599, 'refunded');