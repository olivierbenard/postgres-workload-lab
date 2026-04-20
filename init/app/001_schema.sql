CREATE TABLE customers (
    customer_id BIGSERIAL PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    country_code TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- normalized entities with foreign key constraints...
CREATE TABLE orders (
    order_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
    amount_cents BIGINT NOT NULL,
    status TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ...and compose B-tree index aligned with a common query like
-- "show me the most recent orders for one customer"
CREATE INDEX idx_orders_customer_created_at
    ON orders (customer_id, created_at DESC);
