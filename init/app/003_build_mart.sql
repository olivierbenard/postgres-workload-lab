-- IMPORTANT: if later partial refunds or refunds happening days later are introduced
-- then, this mart becomes wrong. A better long-term model:
-- separate orders and payments/refunds events
CREATE OR REPLACE VIEW mart_revenue_daily AS
SELECT
    DATE(created_at) AS revenue_date,
    COUNT(*) AS total_orders,
        COUNT(*) FILTER (WHERE status = 'paid') AS paid_orders,
        COUNT(*) FILTER (WHERE status = 'refunded') AS refunded_orders,
        SUM(amount_cents) FILTER (WHERE status = 'paid') AS gross_revenue_cents,  -- what was sold
        SUM(amount_cents) FILTER (WHERE status = 'refunded') AS refunded_amount_cents,  -- what was refunded
        SUM(
            CASE
                WHEN status = 'paid' THEN amount_cents
                WHEN status = 'refunded' THEN -amount_cents
            ELSE 0
        END
    ) AS net_revenue_cents -- what matters (sold - refunded)
FROM orders -- no joins needed = fast + AI-friendly
GROUP BY 1;