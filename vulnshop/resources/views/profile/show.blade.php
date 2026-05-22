@extends('layouts.app')
@section('title','Profile')
@section('content')
<div class="card" style="max-width:500px;">
    <h2>Profile</h2><br>
    @if($user->avatar)
        <img src="{{ $user->avatar }}" alt="Avatar" style="width:100px;height:100px;border-radius:50%;object-fit:cover;"><br><br>
    @endif
    <p><strong>Name:</strong>   {{ $user->name }}</p>
    <p><strong>Email:</strong>  {{ $user->email }}</p>
    <p><strong>Role:</strong>   {{ $user->role }}</p>
    <p><strong>Joined:</strong> {{ $user->created_at->format('d M Y') }}</p>
    <br>
    <h4>Upload Avatar</h4>
    {{-- VULNERABILITY: Accepts any file type — PHP webshell upload possible (CWE-434) --}}
    <form method="POST" action="/profile/upload-avatar" enctype="multipart/form-data">
        @csrf
        <input type="file" name="avatar" required>
        <button type="submit" class="btn">Upload</button>
    </form>
</div>
@endsection
