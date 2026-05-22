<?php
namespace App\Http\Middleware;

use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken as Middleware;

class VerifyCsrfToken extends Middleware
{
    // VULNERABILITY: Password-change and checkout routes excluded from CSRF protection (CWE-352 / OWASP A01:2021)
    protected $except = [
        '/change-password',
        '/checkout',
    ];
}
