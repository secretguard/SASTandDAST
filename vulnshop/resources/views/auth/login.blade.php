@extends('layouts.app')
@section('title','Login')
@section('content')
<div class="card" style="max-width:400px;margin:40px auto;">
    <h2>Login</h2><br>
    <form method="POST" action="/login">
        @csrf
        <label>Email</label>
        <input type="email" name="email" required>
        <label>Password</label>
        <input type="password" name="password" required>
        <button type="submit" class="btn" style="width:100%;">Login</button>
    </form>
    <p style="margin-top:15px;text-align:center;">No account? <a href="/register">Register</a></p>
</div>
@endsection
