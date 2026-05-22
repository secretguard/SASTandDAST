<?php
namespace App\Http\Controllers;

use App\Models\Review;
use Illuminate\Http\Request;

class ReviewController extends Controller
{
    // VULNERABILITY: No input sanitisation — comment stored raw and rendered unescaped
    //                Leads to Stored XSS (CWE-79 / OWASP A03:2021)
    public function store(Request $request, $productId)
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        Review::create([
            'product_id' => $productId,
            'user_id'    => $userId,
            'rating'     => $request->input('rating', 5),
            'comment'    => $request->input('comment'),  // stored without sanitisation
        ]);

        return back()->with('success', 'Review posted!');
    }
}
