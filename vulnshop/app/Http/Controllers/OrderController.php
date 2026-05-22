<?php
namespace App\Http\Controllers;

use App\Models\Order;
use App\Models\OrderItem;
use Illuminate\Http\Request;

class OrderController extends Controller
{
    public function index()
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $orders = Order::where('user_id', $userId)->orderBy('created_at', 'desc')->get();
        return view('orders.index', compact('orders'));
    }

    // VULNERABILITY: IDOR — no ownership check, any user can view any order by ID (CWE-639 / OWASP A01:2021)
    public function show($id)
    {
        $order = Order::with('items.product')->findOrFail($id);
        return view('orders.show', compact('order'));
    }

    // VULNERABILITY: Price manipulation — total and item prices taken from client request (CWE-602)
    public function checkout(Request $request)
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $order = Order::create([
            'user_id'          => $userId,
            'shipping_name'    => $request->input('shipping_name'),
            'shipping_address' => $request->input('shipping_address'),
            'phone'            => $request->input('phone'),
            'total'            => $request->input('total'),   // VULNERABLE: client-submitted total
            'status'           => 'pending',
        ]);

        foreach ($request->input('items', []) as $item) {
            OrderItem::create([
                'order_id'   => $order->id,
                'product_id' => $item['product_id'],
                'quantity'   => $item['quantity'],
                'price'      => $item['price'],               // VULNERABLE: client-submitted price
            ]);
        }

        return redirect("/order/{$order->id}")->with('success', 'Order placed!');
    }
}
