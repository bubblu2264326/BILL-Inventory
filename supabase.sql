-- Enable necessary extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create ENUM types for status
CREATE TYPE order_status AS ENUM ('pending', 'processing', 'completed', 'cancelled');
CREATE TYPE payment_status AS ENUM ('pending', 'paid', 'failed', 'refunded');

-- Users table with roles
CREATE TABLE users (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    full_name TEXT NOT NULL,
    role TEXT CHECK (role IN ('admin', 'staff', 'manager')) NOT NULL,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Categories table
CREATE TABLE categories (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Products table with category relation
CREATE TABLE products (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    category_id UUID REFERENCES categories(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    description TEXT,
    sku TEXT UNIQUE NOT NULL,
    price DECIMAL(10,2) NOT NULL CHECK (price >= 0),
    cost_price DECIMAL(10,2) NOT NULL CHECK (cost_price >= 0),
    stock_quantity INTEGER NOT NULL DEFAULT 0,
    reorder_level INTEGER NOT NULL DEFAULT 10,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Suppliers table
CREATE TABLE suppliers (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    name TEXT NOT NULL,
    contact_person TEXT,
    email TEXT,
    phone TEXT,
    address TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Purchase orders
CREATE TABLE purchase_orders (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    supplier_id UUID REFERENCES suppliers(id),
    user_id UUID REFERENCES users(id),
    order_date TIMESTAMPTZ DEFAULT NOW(),
    total_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
    status order_status DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Purchase order items
CREATE TABLE purchase_order_items (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    purchase_order_id UUID REFERENCES purchase_orders(id) ON DELETE CASCADE,
    product_id UUID REFERENCES products(id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price DECIMAL(10,2) NOT NULL CHECK (unit_price >= 0),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sales orders
CREATE TABLE sales_orders (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    user_id UUID REFERENCES users(id),
    customer_name TEXT,
    total_amount DECIMAL(10,2) NOT NULL DEFAULT 0,
    payment_status payment_status DEFAULT 'pending',
    status order_status DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Sales order items
CREATE TABLE sales_order_items (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    sales_order_id UUID REFERENCES sales_orders(id) ON DELETE CASCADE,
    product_id UUID REFERENCES products(id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price DECIMAL(10,2) NOT NULL CHECK (unit_price >= 0),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Inventory transactions log
CREATE TABLE inventory_transactions (
    id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    product_id UUID REFERENCES products(id),
    transaction_type TEXT CHECK (transaction_type IN ('purchase', 'sale', 'adjustment')),
    quantity INTEGER NOT NULL,
    reference_id UUID,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Apply updated_at triggers to all relevant tables
CREATE TRIGGER update_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Similar triggers for other tables...

-- Inventory management trigger
CREATE OR REPLACE FUNCTION update_inventory_after_sale()
RETURNS TRIGGER AS $$
BEGIN
    -- Update product stock
    UPDATE products
    SET stock_quantity = stock_quantity - NEW.quantity
    WHERE id = NEW.product_id;
    
    -- Log transaction
    INSERT INTO inventory_transactions (
        product_id,
        transaction_type,
        quantity,
        reference_id,
        notes
    ) VALUES (
        NEW.product_id,
        'sale',
        -NEW.quantity,
        NEW.sales_order_id,
        'Sale order item'
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_sale_order_item_insert
    AFTER INSERT ON sales_order_items
    FOR EACH ROW
    EXECUTE FUNCTION update_inventory_after_sale();

-- Create procedure for creating a sale with transaction
CREATE OR REPLACE PROCEDURE create_sale(
    p_user_id UUID,
    p_customer_name TEXT,
    p_items JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sale_id UUID;
    v_item JSONB;
    v_total DECIMAL(10,2) := 0;
BEGIN
    -- Start transaction
    BEGIN
        -- Create sale order
        INSERT INTO sales_orders (user_id, customer_name)
        VALUES (p_user_id, p_customer_name)
        RETURNING id INTO v_sale_id;
        
        -- Process each item
        FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
        LOOP
            -- Check stock availability
            IF (SELECT stock_quantity FROM products WHERE id = (v_item->>'product_id')::UUID) < (v_item->>'quantity')::INTEGER THEN
                RAISE EXCEPTION 'Insufficient stock for product %', (v_item->>'product_id')::UUID;
            END IF;
            
            -- Insert sale item
            INSERT INTO sales_order_items (
                sales_order_id,
                product_id,
                quantity,
                unit_price
            ) VALUES (
                v_sale_id,
                (v_item->>'product_id')::UUID,
                (v_item->>'quantity')::INTEGER,
                (v_item->>'unit_price')::DECIMAL
            );
            
            -- Update total
            v_total := v_total + ((v_item->>'quantity')::INTEGER * (v_item->>'unit_price')::DECIMAL);
        END LOOP;
        
        -- Update sale total
        UPDATE sales_orders
        SET total_amount = v_total
        WHERE id = v_sale_id;
        
        -- Commit transaction
        COMMIT;
    EXCEPTION WHEN OTHERS THEN
        -- Rollback transaction
        ROLLBACK;
        RAISE;
    END;
END;
$$;

-- Create view for low stock products
CREATE VIEW low_stock_products AS
SELECT 
    p.id,
    p.name,
    p.stock_quantity,
    p.reorder_level,
    c.name as category_name
FROM products p
JOIN categories c ON p.category_id = c.id
WHERE p.stock_quantity <= p.reorder_level;

-- Create view for sales analytics
CREATE VIEW sales_analytics AS
SELECT 
    DATE_TRUNC('day', so.created_at) as sale_date,
    COUNT(DISTINCT so.id) as total_orders,
    SUM(so.total_amount) as total_revenue,
    AVG(so.total_amount) as average_order_value
FROM sales_orders so
WHERE so.status = 'completed'
GROUP BY DATE_TRUNC('day', so.created_at)
ORDER BY sale_date DESC;
