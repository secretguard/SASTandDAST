<?php
namespace App\Http\Controllers;

use App\Models\User;
use Illuminate\Http\Request;

class AuthController extends Controller
{
    public function showLogin()    { return view('auth.login'); }
    public function showRegister() { return view('auth.register'); }
    public function showChangePassword() { return view('auth.change-password'); }

    // VULNERABILITY: No rate limiting — brute-force login possible (CWE-307)
    public function login(Request $request)
    {
        $email    = $request->input('email');
        $password = md5($request->input('password'));   // VULNERABILITY: MD5 (CWE-328)

        $user = User::where('email', $email)->where('password', $password)->first();

        if ($user) {
            session(['user_id' => $user->id, 'user_name' => $user->name, 'user_role' => $user->role]);
            return redirect('/dashboard');
        }

        return back()->with('error', 'Invalid credentials');
    }

    public function register(Request $request)
    {
        $user = User::create([
            'name'     => $request->input('name'),
            'email'    => $request->input('email'),
            'password' => $request->input('password'),
            'role'     => 'customer',
        ]);

        session(['user_id' => $user->id, 'user_name' => $user->name, 'user_role' => $user->role]);
        return redirect('/dashboard');
    }

    public function logout()
    {
        // VULNERABILITY: Session not fully invalidated — session ID not rotated (CWE-384)
        session()->forget(['user_id', 'user_name', 'user_role']);
        return redirect('/login');
    }

    // VULNERABILITY: No CSRF protection — /change-password is excluded in VerifyCsrfToken (CWE-352)
    public function changePassword(Request $request)
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $user = User::find($userId);
        $user->password = $request->input('new_password');
        $user->save();

        return back()->with('success', 'Password changed successfully');
    }
}
