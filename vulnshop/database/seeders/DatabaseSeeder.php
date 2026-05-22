<?php
namespace Database\Seeders;

use Illuminate\Database\Seeder;
use App\Models\User;
use App\Models\Product;
use App\Models\Order;
use App\Models\OrderItem;
use App\Models\Review;

class DatabaseSeeder extends Seeder
{
    public function run(): void
    {
        $admin = User::create([
            'name'     => 'Admin',
            'email'    => 'admin@vulnshop.local',
            'password' => 'admin123',
            'role'     => 'admin',
        ]);

        $alice = User::create([
            'name'     => 'Alice Johnson',
            'email'    => 'alice@example.com',
            'password' => 'password123',
            'role'     => 'customer',
        ]);

        $bob = User::create([
            'name'     => 'Bob Smith',
            'email'    => 'bob@example.com',
            'password' => 'password123',
            'role'     => 'customer',
        ]);

        $products = [
            ['name' => 'Wireless Bluetooth Headphones',  'description' => 'Premium noise-cancelling over-ear headphones with 30-hour battery life and deep bass.',                                              'price' => 4999.00, 'stock' => 50],
            ['name' => 'Smart Fitness Tracker Pro',       'description' => 'Heart rate, SpO2, GPS tracking, sleep analysis, 14-day battery. Water resistant to 50 m.',                                          'price' => 3499.00, 'stock' => 120],
            ['name' => 'Mechanical Gaming Keyboard',      'description' => 'RGB backlit mechanical keyboard with Cherry MX Blue switches and aircraft-grade aluminium body.',                                    'price' => 7999.00, 'stock' => 35],
            ['name' => 'Ultra-Slim Laptop Stand',         'description' => 'Ergonomic aluminium stand with adjustable height and angle. Foldable for portability.',                                             'price' => 1999.00, 'stock' => 200],
            ['name' => '4K Webcam with Ring Light',       'description' => 'Professional 4K webcam with built-in ring light, auto-focus, and noise-cancelling dual microphones.',                               'price' => 5999.00, 'stock' => 65],
            ['name' => 'Portable SSD 1TB',                'description' => 'Ultra-fast USB-C SSD: 1050 MB/s read, 256-bit AES encryption, shock-resistant aluminium shell.',                                   'price' => 8499.00, 'stock' => 80],
            ['name' => 'Smart Home Security Camera',      'description' => '1080p WiFi camera with night vision, two-way audio, motion detection, and cloud storage. Works with Alexa.',                       'price' => 2999.00, 'stock' => 150],
            ['name' => 'Wireless Charging Pad',           'description' => '15W fast wireless charging pad for all Qi-enabled devices. LED indicator and anti-slip surface.',                                   'price' => 1499.00, 'stock' => 300],
        ];

        foreach ($products as $p) {
            Product::create($p);
        }

        // Alice's order (used as IDOR target: users should only see their own orders)
        $order1 = Order::create([
            'user_id'          => $alice->id,
            'shipping_name'    => 'Alice Johnson',
            'shipping_address' => '123 Tech Street, Bangalore, KA 560001',
            'phone'            => '+91 9876543210',
            'total'            => 12498.00,
            'status'           => 'pending',
        ]);
        OrderItem::create(['order_id' => $order1->id, 'product_id' => 1, 'quantity' => 1, 'price' => 4999.00]);
        OrderItem::create(['order_id' => $order1->id, 'product_id' => 4, 'quantity' => 1, 'price' => 1999.00]);
        OrderItem::create(['order_id' => $order1->id, 'product_id' => 6, 'quantity' => 1, 'price' => 8499.00]);

        // Bob's order (cross-user IDOR target)
        $order2 = Order::create([
            'user_id'          => $bob->id,
            'shipping_name'    => 'Bob Smith',
            'shipping_address' => '456 Cyber Lane, Mumbai, MH 400001',
            'phone'            => '+91 9123456789',
            'total'            => 7999.00,
            'status'           => 'shipped',
        ]);
        OrderItem::create(['order_id' => $order2->id, 'product_id' => 3, 'quantity' => 1, 'price' => 7999.00]);

        Review::create(['product_id' => 1, 'user_id' => $alice->id, 'rating' => 5, 'comment' => 'Amazing sound quality! Best headphones I have ever used.']);
        Review::create(['product_id' => 1, 'user_id' => $bob->id,   'rating' => 4, 'comment' => 'Great bass, but a bit heavy for long sessions.']);
        Review::create(['product_id' => 3, 'user_id' => $bob->id,   'rating' => 5, 'comment' => 'Cherry MX Blues are so satisfying. Build quality is top notch.']);
        Review::create(['product_id' => 6, 'user_id' => $alice->id, 'rating' => 5, 'comment' => 'Incredibly fast transfers. Worth every rupee.']);
    }
}
