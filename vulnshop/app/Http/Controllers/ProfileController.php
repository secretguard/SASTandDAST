<?php
namespace App\Http\Controllers;

use App\Models\User;
use Illuminate\Http\Request;

class ProfileController extends Controller
{
    public function show()
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $user = User::find($userId);
        return view('profile.show', compact('user'));
    }

    // VULNERABILITY: Insecure file upload — no type validation, uses original filename,
    //                stores in public directory, allows PHP webshell upload (CWE-434 / OWASP A04:2021)
    public function uploadAvatar(Request $request)
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        if ($request->hasFile('avatar')) {
            $file     = $request->file('avatar');
            $filename = $file->getClientOriginalName();                  // VULNERABLE: no sanitisation
            $file->move(public_path('uploads/avatars'), $filename);      // VULNERABLE: no type check

            $user = User::find($userId);
            $user->avatar = '/uploads/avatars/' . $filename;
            $user->save();

            return back()->with('success', 'Avatar updated!');
        }

        return back()->with('error', 'No file uploaded');
    }
}
