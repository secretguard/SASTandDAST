@extends('layouts.app')
@section('title','Order Details')
@section('content')
<div class="card">
    <h2>Order #{{ $order->id }}</h2>
    <p><strong>Date:</strong>    {{ $order->created_at->format('d M Y H:i') }}</p>
    <p><strong>Status:</strong>  <span class="tag tag-warning">{{ $order->status }}</span></p>
    <p><strong>Ship to:</strong> {{ $order->shipping_name }}</p>
    <p><strong>Address:</strong> {{ $order->shipping_address }}</p>
    <p><strong>Phone:</strong>   {{ $order->phone }}</p>
    <br>
    <table>
        <tr><th>Product</th><th>Qty</th><th>Price</th><th>Subtotal</th></tr>
        @foreach($order->items as $item)
        <tr>
            <td>{{ $item->product->name ?? 'N/A' }}</td>
            <td>{{ $item->quantity }}</td>
            <td>₹{{ number_format($item->price, 2) }}</td>
            <td>₹{{ number_format($item->price * $item->quantity, 2) }}</td>
        </tr>
        @endforeach
    </table>
    <br>
    <p style="font-size:1.3em;text-align:right;"><strong>Total: ₹{{ number_format($order->total, 2) }}</strong></p>
</div>
@endsection
