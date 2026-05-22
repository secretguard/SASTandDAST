<?php
use App\Http\Controllers\AuthController;
use App\Http\Controllers\ProductController;
use App\Http\Controllers\ReviewController;
use App\Http\Controllers\OrderController;
use App\Http\Controllers\ProfileController;
use App\Http\Controllers\DashboardController;
use Illuminate\Support\Facades\Route;

// ── Public ────────────────────────────────────────────────────────────────────
Route::get('/', fn() => redirect('/products'));

Route::get('/login',    [AuthController::class, 'showLogin']);
Route::post('/login',   [AuthController::class, 'login']);          // VULN: no rate limit
Route::get('/register', [AuthController::class, 'showRegister']);
Route::post('/register',[AuthController::class, 'register']);
Route::get('/logout',   [AuthController::class, 'logout']);

// ── Products (public) ─────────────────────────────────────────────────────────
Route::get('/products',        [ProductController::class, 'index']);
Route::get('/products/search', [ProductController::class, 'search']);   // VULN: SQLi
Route::get('/products/{id}',   [ProductController::class, 'show']);

// ── Authenticated (no auth middleware — missing access control is intentional) ─
Route::post('/products/{id}/review', [ReviewController::class, 'store']);  // VULN: Stored XSS
Route::get('/dashboard',             [DashboardController::class, 'index']);
Route::get('/orders',                [OrderController::class, 'index']);
Route::get('/order/{id}',            [OrderController::class, 'show']);    // VULN: IDOR
Route::post('/checkout',             [OrderController::class, 'checkout']); // VULN: price manipulation + no CSRF
Route::get('/profile',               [ProfileController::class, 'show']);
Route::post('/profile/upload-avatar',[ProfileController::class, 'uploadAvatar']); // VULN: insecure upload
Route::get('/change-password',       [AuthController::class, 'showChangePassword']);
Route::post('/change-password',      [AuthController::class, 'changePassword']); // VULN: no CSRF

// ── VULNERABILITY: Sensitive debug information exposed via API endpoint ────────
// OWASP A05:2021 — Security Misconfiguration | CWE-200
Route::get('/debug-info', function () {
    return response()->json([
        'php_version'     => phpversion(),
        'laravel_version' => app()->version(),
        'db_host'         => env('DB_HOST'),
        'db_name'         => env('DB_DATABASE'),
        'app_key'         => env('APP_KEY'),
        'debug_mode'      => env('APP_DEBUG'),
        'admin_email'     => env('ADMIN_EMAIL'),
    ]);
});
