@extends('layouts.app')
@section('title','Dashboard')
@section('content')
<h2>Welcome, {{ session('user_name') }}!</h2><br>
<div class="grid">
    <div class="card">
        <h3>Recent Orders</h3><br>
        @if(count($orders) > 0)
        <table>
            <tr><th>Order #</th><th>Total</th><th>Status</th></tr>
            @foreach($orders as $order)
            <tr>
                <td><a href="/order/{{ $order->id }}">#{{ $order->id }}</a></td>
                <td>₹{{ number_format($order->total, 2) }}</td>
                <td><span class="tag tag-warning">{{ $order->status }}</span></td>
            </tr>
            @endforeach
        </table>
        @else
        <p>No orders yet.</p>
        @endif
    </div>
    <div class="card">
        <h3>Quick Links</h3><br>
        <p><a href="/products" class="btn">Browse Products</a></p><br>
        <p><a href="/profile" class="btn btn-secondary">Edit Profile</a></p><br>
        <p><a href="/change-password" class="btn btn-secondary">Change Password</a></p>
    </div>
</div>
@endsection
