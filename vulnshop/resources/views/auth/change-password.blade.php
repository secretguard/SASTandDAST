@extends('layouts.app')
@section('title','Change Password')
@section('content')
<div class="card" style="max-width:400px;margin:40px auto;">
    <h2>Change Password</h2><br>
    {{-- VULNERABILITY: No CSRF token — this form is excluded from VerifyCsrfToken (CWE-352) --}}
    <form method="POST" action="/change-password">
        <label>New Password</label>
        <input type="password" name="new_password" required>
        <label>Confirm Password</label>
        <input type="password" name="confirm_password" required>
        <button type="submit" class="btn" style="width:100%;">Change Password</button>
    </form>
</div>
@endsection
