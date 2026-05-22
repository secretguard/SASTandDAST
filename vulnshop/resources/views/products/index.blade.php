@extends('layouts.app')
@section('title','Products')
@section('content')
<h2>Products</h2><br>
<form action="/products/search" method="GET" class="search-bar">
    <input type="text" name="q" placeholder="Search products..." value="{{ request('q') }}">
    <button type="submit" class="btn">Search</button>
</form>
<div class="grid">
    @foreach($products as $product)
    <div class="card">
        <h3>{{ $product->name }}</h3>
        <p style="color:#888;margin:8px 0;">{{ Str::limit($product->description, 100) }}</p>
        <p style="font-size:1.3em;font-weight:bold;color:#e94560;">₹{{ number_format($product->price, 2) }}</p>
        <br>
        <a href="/products/{{ $product->id }}" class="btn">View Details</a>
    </div>
    @endforeach
</div>
@endsection
