@extends('layouts.app')
@section('title', $product->name)
@section('content')
<div class="card">
    <h2>{{ $product->name }}</h2>
    <p style="margin:15px 0;">{{ $product->description }}</p>
    <p style="font-size:1.5em;font-weight:bold;color:#e94560;">₹{{ number_format($product->price, 2) }}</p>
    <p style="color:#888;">Stock: {{ $product->stock }} available</p>
    <br>
    @if(session('user_id'))
    <form method="POST" action="/checkout">
        @csrf
        <input type="hidden" name="items[0][product_id]" value="{{ $product->id }}">
        <input type="hidden" name="items[0][quantity]"   value="1">
        {{-- VULNERABILITY: Price sent from client — can be manipulated (CWE-602) --}}
        <input type="hidden" name="items[0][price]"      value="{{ $product->price }}">
        <input type="hidden" name="total"                value="{{ $product->price }}">
        <input type="text"   name="shipping_name"    placeholder="Your Name"         required>
        <input type="text"   name="shipping_address" placeholder="Shipping Address"  required>
        <input type="text"   name="phone"            placeholder="Phone Number"      required>
        <button type="submit" class="btn">Buy Now</button>
    </form>
    @else
    <p><a href="/login" class="btn">Login to Purchase</a></p>
    @endif
</div>

<div class="card">
    <h3>Customer Reviews</h3><br>
    @foreach($product->reviews as $review)
    <div style="padding:10px 0;border-bottom:1px solid #eee;">
        <strong>{{ $review->user->name ?? 'Anonymous' }}</strong>
        <span style="color:#e94560;">★ {{ $review->rating }}/5</span>
        <span style="color:#888;font-size:.85em;">{{ $review->created_at->diffForHumans() }}</span>
        {{-- VULNERABILITY: Stored XSS — comment rendered without escaping (CWE-79) --}}
        <p style="margin-top:5px;">{!! $review->comment !!}</p>
    </div>
    @endforeach

    @if(session('user_id'))
    <br>
    <h4>Write a Review</h4>
    <form method="POST" action="/products/{{ $product->id }}/review">
        @csrf
        <select name="rating">
            <option value="5">★★★★★ (5)</option>
            <option value="4">★★★★ (4)</option>
            <option value="3">★★★ (3)</option>
            <option value="2">★★ (2)</option>
            <option value="1">★ (1)</option>
        </select>
        <textarea name="comment" rows="3" placeholder="Write your review..." required></textarea>
        <button type="submit" class="btn">Submit Review</button>
    </form>
    @endif
</div>
@endsection
