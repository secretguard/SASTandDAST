<?php
namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;

class User extends Authenticatable
{
    protected $fillable = ['name', 'email', 'password', 'role', 'avatar'];
    protected $hidden   = ['password'];

    // VULNERABILITY: MD5 used instead of bcrypt (CWE-328)
    public function setPasswordAttribute($value)
    {
        $this->attributes['password'] = md5($value);
    }

    public function orders()  { return $this->hasMany(Order::class); }
    public function reviews() { return $this->hasMany(Review::class); }
}
