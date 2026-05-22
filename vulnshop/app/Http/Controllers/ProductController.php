<?php
namespace App\Http\Controllers;

use App\Models\Product;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class ProductController extends Controller
{
    public function index()
    {
        $products = Product::all();
        return view('products.index', compact('products'));
    }

    // VULNERABILITY: SQL Injection via string concatenation in raw query (CWE-89 / OWASP A03:2021)
    public function search(Request $request)
    {
        $query = $request->input('q', '');

        // VULNERABLE — do not fix: direct user input interpolated into SQL
        $products = DB::select(
            "SELECT * FROM products WHERE name LIKE '%" . $query . "%' OR description LIKE '%" . $query . "%'"
        );

        return view('products.search', compact('products', 'query'));
    }

    public function show($id)
    {
        $product = Product::with('reviews.user')->findOrFail($id);
        return view('products.show', compact('product'));
    }
}
