CREATE TABLE IF NOT EXISTS orders (
    id          SERIAL PRIMARY KEY,
    customer_id INT NOT NULL,
    amount      NUMERIC(10,2),
    status      VARCHAR(20) DEFAULT 'pending',
    created_at  TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id);

INSERT INTO orders (customer_id, amount, status)
VALUES (1, 10.50, 'paid'), (2, 99.99, 'pending'), (3, 5.00, 'cancelled');