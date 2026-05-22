@extends('layouts.app')
@section('title','Register')
@section('content')
<div class="card" style="max-width:400px;margin:40px auto;">
    <h2>Register</h2><br>
    <form method="POST" action="/register">
        @csrf
        <label>Name</label>
        <input type="text" name="name" required>
        <label>Email</label>
        <input type="email" name="email" required>
        <label>Password</label>
        <input type="password" name="password" required>
        <button type="submit" class="btn" style="width:100%;">Register</button>
    </form>
</div>
@endsection
