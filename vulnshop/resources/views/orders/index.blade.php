@extends('layouts.app')
@section('title','My Orders')
@section('content')
<h2>My Orders</h2><br>
@if(count($orders) > 0)
<div class="card">
    <table>
        <tr><th>Order #</th><th>Date</th><th>Total</th><th>Status</th><th>Action</th></tr>
        @foreach($orders as $order)
        <tr>
            <td>#{{ $order->id }}</td>
            <td>{{ $order->created_at->format('d M Y') }}</td>
            <td>₹{{ number_format($order->total, 2) }}</td>
            <td><span class="tag tag-warning">{{ $order->status }}</span></td>
            {{-- VULNERABILITY: Order ID visible in URL — IDOR if server has no ownership check --}}
            <td><a href="/order/{{ $order->id }}" class="btn" style="padding:5px 12px;font-size:.85em;">View</a></td>
        </tr>
        @endforeach
    </table>
</div>
@else
<div class="card"><p>No orders yet. <a href="/products">Browse products</a></p></div>
@endif
@endsection
