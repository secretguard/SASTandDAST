<?php
namespace App\Http\Controllers;

use App\Models\Order;
use App\Models\Product;

class DashboardController extends Controller
{
    public function index()
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $orders   = Order::where('user_id', $userId)->latest()->take(5)->get();
        $products = Product::latest()->take(6)->get();

        return view('dashboard', compact('orders', 'products'));
    }
}
