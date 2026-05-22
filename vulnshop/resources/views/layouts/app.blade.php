<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VulnShop — @yield('title', 'Home')</title>
    <style>
        * { margin:0; padding:0; box-sizing:border-box; }
        body { font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif; background:#f5f5f5; color:#333; }
        .navbar { background:#1a1a2e; color:#fff; padding:15px 30px; display:flex; justify-content:space-between; align-items:center; }
        .navbar a { color:#eee; text-decoration:none; margin:0 15px; }
        .navbar a:hover { color:#e94560; }
        .brand { font-size:1.4em; font-weight:bold; color:#e94560; }
        .container { max-width:1100px; margin:30px auto; padding:0 20px; }
        .card { background:#fff; border-radius:8px; padding:20px; margin-bottom:20px; box-shadow:0 2px 4px rgba(0,0,0,.1); }
        .btn { display:inline-block; padding:10px 20px; background:#e94560; color:#fff; border:none; border-radius:5px; cursor:pointer; text-decoration:none; font-size:.95em; }
        .btn:hover { background:#c73e54; }
        .btn-secondary { background:#16213e; }
        input,textarea,select { width:100%; padding:10px; margin:8px 0 16px; border:1px solid #ddd; border-radius:5px; font-size:.95em; }
        .alert { padding:12px 20px; border-radius:5px; margin-bottom:15px; }
        .alert-success { background:#d4edda; color:#155724; border:1px solid #c3e6cb; }
        .alert-error   { background:#f8d7da; color:#721c24; border:1px solid #f5c6cb; }
        .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(300px,1fr)); gap:20px; }
        table { width:100%; border-collapse:collapse; }
        th,td { padding:10px 15px; text-align:left; border-bottom:1px solid #eee; }
        th { background:#1a1a2e; color:#fff; }
        .search-bar { display:flex; gap:10px; margin-bottom:20px; }
        .search-bar input { flex:1; }
        .tag { display:inline-block; padding:3px 10px; border-radius:12px; font-size:.8em; }
        .tag-warning { background:#fff3cd; color:#856404; }
        footer { text-align:center; padding:20px; color:#888; font-size:.85em; margin-top:40px; }
    </style>
</head>
<body>
<nav class="navbar">
    <span class="brand">VulnShop</span>
    <div>
        <a href="/products">Products</a>
        @if(session('user_id'))
            <a href="/dashboard">Dashboard</a>
            <a href="/orders">My Orders</a>
            <a href="/profile">Profile</a>
            <a href="/logout">Logout ({{ session('user_name') }})</a>
        @else
            <a href="/login">Login</a>
            <a href="/register">Register</a>
        @endif
    </div>
</nav>

<div class="container">
    @if(session('success'))
        <div class="alert alert-success">{{ session('success') }}</div>
    @endif
    @if(session('error'))
        <div class="alert alert-error">{{ session('error') }}</div>
    @endif
    @yield('content')
</div>

{{-- VULNERABILITY: Server version info exposed in footer (CWE-200) --}}
<footer>
    VulnShop v1.0 &nbsp;|&nbsp; Laravel {{ app()->version() }} &nbsp;|&nbsp; PHP {{ phpversion() }}
    &nbsp;|&nbsp; {{ $_SERVER['SERVER_SOFTWARE'] ?? 'Unknown' }}
</footer>
</body>
</html>
