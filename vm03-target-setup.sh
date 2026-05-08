#!/bin/bash
###############################################################################
# VM-03: Vulnerable Target Server — DVWA + VulnShop
# Master Kit Setup Script
# OS: Ubuntu 22.04 LTS | CPU: 4 vCPU | RAM: 8 GB | Disk: 80 GB SSD
#
# This script installs and configures:
#   - Apache2 with mod_rewrite
#   - PHP 8.1 with required extensions
#   - MySQL (MariaDB)
#   - DVWA (Damn Vulnerable Web Application)
#   - VulnShop (custom vulnerable Laravel e-commerce app)
#   - Lab user with SSH access
#
# Run as root: sudo bash vm03-target-setup.sh
###############################################################################

set -euo pipefail

# ─── CONFIGURATION ───────────────────────────────────────────────────────────
LAB_USER="${LAB_USER:-$(logname 2>/dev/null || echo "labuser")}"
LAB_HOME="${LAB_HOME:-/home/$LAB_USER}"
THIS_IP="${THIS_IP:-$(hostname -I | awk '{print $1}')}"
VM01_IP="${VM01_IP:-}"
VM02_IP="${VM02_IP:-}"
VM03_IP="${VM03_IP:-$THIS_IP}"

DVWA_DB_USER="dvwa"
DVWA_DB_PASS="dvwa_pass"
DVWA_DB_NAME="dvwa"

VULNSHOP_DB_USER="vulnshop_user"
VULNSHOP_DB_PASS="vulnshop_pass"
VULNSHOP_DB_NAME="vulnshop"

LOG_FILE="/var/log/vm03-setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================================================"
echo " VM-03 SETUP — Vulnerable Target Server (DVWA + VulnShop)"
echo " Started: $(date)"
echo "======================================================================"

# ─── STEP 1: SYSTEM PREP ────────────────────────────────────────────────────
echo ""
echo "[STEP 1/12] System update and base packages..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget unzip git net-tools vim nano htop tree jq \
  software-properties-common apt-transport-https ca-certificates \
  gnupg lsb-release ufw openssh-server

# ─── STEP 2: CREATE LAB USER ────────────────────────────────────────────────
echo ""
echo "[STEP 2/12] Verifying lab user: $LAB_USER..."

if ! id "$LAB_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G sudo "$LAB_USER"
  echo "  Created user $LAB_USER. Set a password with: sudo passwd $LAB_USER"
fi
if [ ! -f "/etc/sudoers.d/$LAB_USER" ]; then
  echo "$LAB_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$LAB_USER"
  chmod 440 "/etc/sudoers.d/$LAB_USER"
fi
echo "  Lab user: $LAB_USER (home: $LAB_HOME)"

# ─── STEP 3: SSH CONFIGURATION ──────────────────────────────────────────────
echo ""
echo "[STEP 3/12] Configuring SSH..."

sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

# ─── STEP 4: INSTALL APACHE + PHP ───────────────────────────────────────────
echo ""
echo "[STEP 4/12] Installing Apache2 and PHP 8.1..."

apt-get install -y -qq \
  apache2 libapache2-mod-php \
  php php-cli php-common php-mysql php-gd php-xml php-mbstring \
  php-curl php-zip php-bcmath php-json php-tokenizer php-intl \
  php-readline php-fileinfo php-dom php-pdo

# Enable required Apache modules
a2enmod rewrite
a2enmod headers
a2enmod ssl

# Allow .htaccess overrides
sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf

echo "  Apache + PHP installed."
php -v 2>&1 | head -1

# ─── STEP 5: INSTALL MARIADB ────────────────────────────────────────────────
echo ""
echo "[STEP 5/12] Installing MariaDB..."

apt-get install -y -qq mariadb-server mariadb-client
systemctl enable mariadb
systemctl start mariadb

# Secure the installation (non-interactive)
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY ''; FLUSH PRIVILEGES;" 2>/dev/null || true

echo "  MariaDB installed and running."

# ─── STEP 6: INSTALL COMPOSER ───────────────────────────────────────────────
echo ""
echo "[STEP 6/12] Installing Composer..."

if [ ! -f /usr/local/bin/composer ]; then
  cd /tmp
  curl -sS https://getcomposer.org/installer | php
  mv composer.phar /usr/local/bin/composer
  chmod +x /usr/local/bin/composer
fi

echo "  Composer: $(composer --version 2>&1 | head -1)"

# ─── STEP 7: SETUP DVWA ─────────────────────────────────────────────────────
echo ""
echo "[STEP 7/12] Setting up DVWA..."

# Clone DVWA
if [ ! -d /var/www/html/dvwa ]; then
  cd /var/www/html
  git clone https://github.com/digininja/DVWA.git dvwa
fi

# Create DVWA database and user
mysql -e "CREATE DATABASE IF NOT EXISTS $DVWA_DB_NAME;"
mysql -e "CREATE USER IF NOT EXISTS '$DVWA_DB_USER'@'localhost' IDENTIFIED BY '$DVWA_DB_PASS';"
mysql -e "GRANT ALL ON $DVWA_DB_NAME.* TO '$DVWA_DB_USER'@'localhost'; FLUSH PRIVILEGES;"

# Configure DVWA
cd /var/www/html/dvwa/config
if [ -f config.inc.php.dist ] && [ ! -f config.inc.php ]; then
  cp config.inc.php.dist config.inc.php
fi

# Update config
sed -i "s/\$_DVWA\[ 'db_user' \] *= *'.*'/\$_DVWA[ 'db_user' ] = '$DVWA_DB_USER'/" config.inc.php
sed -i "s/\$_DVWA\[ 'db_password' \] *= *'.*'/\$_DVWA[ 'db_password' ] = '$DVWA_DB_PASS'/" config.inc.php
sed -i "s/\$_DVWA\[ 'db_database' \] *= *'.*'/\$_DVWA[ 'db_database' ] = '$DVWA_DB_NAME'/" config.inc.php
# Set default security level to LOW for labs
sed -i "s/\$_DVWA\[ 'default_security_level' \] *= *'.*'/\$_DVWA[ 'default_security_level' ] = 'low'/" config.inc.php
# Enable allow_url_include for file inclusion labs
sed -i 's/^allow_url_include = Off/allow_url_include = On/' /etc/php/*/apache2/php.ini 2>/dev/null || true
sed -i 's/^allow_url_fopen = Off/allow_url_fopen = On/' /etc/php/*/apache2/php.ini 2>/dev/null || true

# Set permissions
chown -R www-data:www-data /var/www/html/dvwa
chmod -R 755 /var/www/html/dvwa
chmod 777 /var/www/html/dvwa/hackable/uploads/
chmod 777 /var/www/html/dvwa/config/
chmod 666 /var/www/html/dvwa/external/phpids/0.6/lib/IDS/tmp/phpids_log.txt 2>/dev/null || true

echo "  DVWA installed at /var/www/html/dvwa"

# ─── STEP 8: BUILD VULNSHOP LARAVEL APPLICATION ─────────────────────────────
echo ""
echo "[STEP 8/12] Building VulnShop vulnerable Laravel application..."

# Create VulnShop database
mysql -e "CREATE DATABASE IF NOT EXISTS $VULNSHOP_DB_NAME;"
mysql -e "CREATE USER IF NOT EXISTS '$VULNSHOP_DB_USER'@'localhost' IDENTIFIED BY '$VULNSHOP_DB_PASS';"
mysql -e "GRANT ALL ON $VULNSHOP_DB_NAME.* TO '$VULNSHOP_DB_USER'@'localhost'; FLUSH PRIVILEGES;"

# Create Laravel project
cd /var/www/html
if [ ! -d vulnshop ]; then
  composer create-project laravel/laravel:^10.0 vulnshop --no-interaction --quiet
fi
cd vulnshop

# ─── VULNSHOP .env (INTENTIONALLY INSECURE) ─────────────────────────────────
cat > .env << ENVFILE
APP_NAME=VulnShop
APP_ENV=production
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost:8080

LOG_CHANNEL=stack
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$VULNSHOP_DB_NAME
DB_USERNAME=$VULNSHOP_DB_USER
DB_PASSWORD=$VULNSHOP_DB_PASS

# VULNERABILITY: Hardcoded admin credentials in config
ADMIN_EMAIL=admin@vulnshop.local
ADMIN_PASSWORD=admin123

SESSION_DRIVER=file
SESSION_LIFETIME=120
ENVFILE

php artisan key:generate --force

# ─── DATABASE MIGRATIONS ────────────────────────────────────────────────────
echo "  Creating database migrations..."

# Users migration (modify default)
cat > database/migrations/2024_01_01_000001_create_users_table.php << 'MIGRATION'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('users', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->string('email')->unique();
            $table->string('password');
            $table->string('role')->default('customer');
            $table->string('avatar')->nullable();
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('users'); }
};
MIGRATION

# Products migration
cat > database/migrations/2024_01_01_000002_create_products_table.php << 'MIGRATION'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('products', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->text('description');
            $table->decimal('price', 10, 2);
            $table->string('image')->nullable();
            $table->integer('stock')->default(100);
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('products'); }
};
MIGRATION

# Orders migration
cat > database/migrations/2024_01_01_000003_create_orders_table.php << 'MIGRATION'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('orders', function (Blueprint $table) {
            $table->id();
            $table->foreignId('user_id')->constrained();
            $table->string('shipping_name');
            $table->text('shipping_address');
            $table->string('phone');
            $table->decimal('total', 10, 2);
            $table->string('status')->default('pending');
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('orders'); }
};
MIGRATION

# Order Items migration
cat > database/migrations/2024_01_01_000004_create_order_items_table.php << 'MIGRATION'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('order_items', function (Blueprint $table) {
            $table->id();
            $table->foreignId('order_id')->constrained()->onDelete('cascade');
            $table->foreignId('product_id')->constrained();
            $table->integer('quantity');
            $table->decimal('price', 10, 2);
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('order_items'); }
};
MIGRATION

# Reviews migration
cat > database/migrations/2024_01_01_000005_create_reviews_table.php << 'MIGRATION'
<?php
use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration {
    public function up(): void
    {
        Schema::create('reviews', function (Blueprint $table) {
            $table->id();
            $table->foreignId('product_id')->constrained()->onDelete('cascade');
            $table->foreignId('user_id')->constrained();
            $table->integer('rating');
            $table->text('comment');
            $table->timestamps();
        });
    }
    public function down(): void { Schema::dropIfExists('reviews'); }
};
MIGRATION

# Remove default Laravel migrations that conflict
rm -f database/migrations/2014_10_12_000000_create_users_table.php 2>/dev/null
rm -f database/migrations/2014_10_12_100000_create_password_reset_tokens_table.php 2>/dev/null
rm -f database/migrations/2019_08_19_000000_create_failed_jobs_table.php 2>/dev/null
rm -f database/migrations/2019_12_14_000001_create_personal_access_tokens_table.php 2>/dev/null

# ─── ELOQUENT MODELS ────────────────────────────────────────────────────────
echo "  Creating Eloquent models..."

cat > app/Models/User.php << 'MODEL'
<?php
namespace App\Models;

use Illuminate\Foundation\Auth\User as Authenticatable;

class User extends Authenticatable
{
    protected $fillable = ['name', 'email', 'password', 'role', 'avatar'];
    protected $hidden = ['password'];

    // VULNERABILITY: MD5 hashing instead of bcrypt
    public function setPasswordAttribute($value)
    {
        $this->attributes['password'] = md5($value);
    }

    public function orders() { return $this->hasMany(Order::class); }
    public function reviews() { return $this->hasMany(Review::class); }
}
MODEL

cat > app/Models/Product.php << 'MODEL'
<?php
namespace App\Models;

use Illuminate\Database\Schema\Blueprint;
use Illuminate\Database\Eloquent\Model;

class Product extends Model
{
    protected $fillable = ['name', 'description', 'price', 'image', 'stock'];

    public function reviews() { return $this->hasMany(Review::class); }
    public function orderItems() { return $this->hasMany(OrderItem::class); }
}
MODEL

cat > app/Models/Order.php << 'MODEL'
<?php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Order extends Model
{
    protected $fillable = ['user_id', 'shipping_name', 'shipping_address', 'phone', 'total', 'status'];

    public function user() { return $this->belongsTo(User::class); }
    public function items() { return $this->hasMany(OrderItem::class); }
}
MODEL

cat > app/Models/OrderItem.php << 'MODEL'
<?php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class OrderItem extends Model
{
    protected $fillable = ['order_id', 'product_id', 'quantity', 'price'];

    public function order() { return $this->belongsTo(Order::class); }
    public function product() { return $this->belongsTo(Product::class); }
}
MODEL

cat > app/Models/Review.php << 'MODEL'
<?php
namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Review extends Model
{
    protected $fillable = ['product_id', 'user_id', 'rating', 'comment'];

    public function product() { return $this->belongsTo(Product::class); }
    public function user() { return $this->belongsTo(User::class); }
}
MODEL

# ─── CONTROLLERS (WITH INTENTIONAL VULNERABILITIES) ─────────────────────────
echo "  Creating controllers with intentional vulnerabilities..."

mkdir -p app/Http/Controllers

cat > app/Http/Controllers/AuthController.php << 'CTRL'
<?php
namespace App\Http\Controllers;

use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class AuthController extends Controller
{
    public function showLogin()
    {
        return view('auth.login');
    }

    // VULNERABILITY: No rate limiting on login
    public function login(Request $request)
    {
        $email = $request->input('email');
        $password = md5($request->input('password'));  // VULNERABILITY: MD5

        $user = User::where('email', $email)->where('password', $password)->first();

        if ($user) {
            session(['user_id' => $user->id, 'user_name' => $user->name, 'user_role' => $user->role]);
            return redirect('/dashboard');
        }

        return back()->with('error', 'Invalid credentials');
    }

    public function showRegister()
    {
        return view('auth.register');
    }

    public function register(Request $request)
    {
        $user = User::create([
            'name' => $request->input('name'),
            'email' => $request->input('email'),
            'password' => $request->input('password'),
            'role' => 'customer',
        ]);

        session(['user_id' => $user->id, 'user_name' => $user->name, 'user_role' => $user->role]);
        return redirect('/dashboard');
    }

    public function logout(Request $request)
    {
        // VULNERABILITY: Session not properly invalidated
        session()->forget(['user_id', 'user_name', 'user_role']);
        return redirect('/login');
    }

    public function showChangePassword()
    {
        return view('auth.change-password');
    }

    // VULNERABILITY: No CSRF protection (excluded in VerifyCsrfToken middleware)
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
CTRL

cat > app/Http/Controllers/ProductController.php << 'CTRL'
<?php
namespace App\Http\Controllers;

use App\Models\Product;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;

class ProductController extends Controller
{
    public function index()
    {
        $products = Product::all();
        return view('products.index', compact('products'));
    }

    // VULNERABILITY: SQL Injection via raw query
    public function search(Request $request)
    {
        $query = $request->input('q', '');

        // VULNERABLE: Direct string concatenation in SQL query
        $products = DB::select("SELECT * FROM products WHERE name LIKE '%" . $query . "%' OR description LIKE '%" . $query . "%'");

        return view('products.search', compact('products', 'query'));
    }

    public function show($id)
    {
        $product = Product::with('reviews.user')->findOrFail($id);
        return view('products.show', compact('product'));
    }
}
CTRL

cat > app/Http/Controllers/ReviewController.php << 'CTRL'
<?php
namespace App\Http\Controllers;

use App\Models\Review;
use Illuminate\Http\Request;

class ReviewController extends Controller
{
    // VULNERABILITY: No input sanitization — Stored XSS
    public function store(Request $request, $productId)
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        Review::create([
            'product_id' => $productId,
            'user_id' => $userId,
            'rating' => $request->input('rating', 5),
            'comment' => $request->input('comment'),  // Stored directly, rendered unescaped
        ]);

        return back()->with('success', 'Review posted!');
    }
}
CTRL

cat > app/Http/Controllers/OrderController.php << 'CTRL'
<?php
namespace App\Http\Controllers;

use App\Models\Order;
use App\Models\OrderItem;
use App\Models\Product;
use Illuminate\Http\Request;

class OrderController extends Controller
{
    public function index()
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $orders = Order::where('user_id', $userId)->orderBy('created_at', 'desc')->get();
        return view('orders.index', compact('orders'));
    }

    // VULNERABILITY: IDOR — No ownership check
    public function show($id)
    {
        // VULNERABLE: Any authenticated user can view any order by changing the ID
        $order = Order::with('items.product')->findOrFail($id);

        return view('orders.show', compact('order'));
    }

    // VULNERABILITY: Price manipulation — trusts client-side price
    public function checkout(Request $request)
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $order = Order::create([
            'user_id' => $userId,
            'shipping_name' => $request->input('shipping_name'),
            'shipping_address' => $request->input('shipping_address'),
            'phone' => $request->input('phone'),
            'total' => $request->input('total'),  // VULNERABLE: Client-submitted total
            'status' => 'pending',
        ]);

        // Process cart items
        $items = $request->input('items', []);
        foreach ($items as $item) {
            OrderItem::create([
                'order_id' => $order->id,
                'product_id' => $item['product_id'],
                'quantity' => $item['quantity'],
                'price' => $item['price'],  // VULNERABLE: Client-submitted price
            ]);
        }

        return redirect("/order/{$order->id}")->with('success', 'Order placed!');
    }
}
CTRL

cat > app/Http/Controllers/ProfileController.php << 'CTRL'
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

    // VULNERABILITY: Insecure file upload — no validation
    public function uploadAvatar(Request $request)
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        if ($request->hasFile('avatar')) {
            $file = $request->file('avatar');

            // VULNERABLE: No file type check, uses original name, stores in public dir
            $filename = $file->getClientOriginalName();
            $file->move(public_path('uploads/avatars'), $filename);

            $user = User::find($userId);
            $user->avatar = '/uploads/avatars/' . $filename;
            $user->save();

            return back()->with('success', 'Avatar updated!');
        }

        return back()->with('error', 'No file uploaded');
    }
}
CTRL

cat > app/Http/Controllers/DashboardController.php << 'CTRL'
<?php
namespace App\Http\Controllers;

use App\Models\Order;
use App\Models\Product;

class DashboardController extends Controller
{
    public function index()
    {
        $userId = session('user_id');
        if (!$userId) return redirect('/login');

        $orders = Order::where('user_id', $userId)->latest()->take(5)->get();
        $products = Product::latest()->take(6)->get();

        return view('dashboard', compact('orders', 'products'));
    }
}
CTRL

# ─── CSRF MIDDLEWARE (INTENTIONALLY WEAKENED) ────────────────────────────────
echo "  Weakening CSRF middleware (intentional vulnerability)..."

cat > app/Http/Middleware/VerifyCsrfToken.php << 'MIDDLEWARE'
<?php
namespace App\Http\Middleware;

use Illuminate\Foundation\Http\Middleware\VerifyCsrfToken as Middleware;

class VerifyCsrfToken extends Middleware
{
    // VULNERABILITY: Password change excluded from CSRF protection
    protected $except = [
        '/change-password',
        '/checkout',
    ];
}
MIDDLEWARE

# ─── ROUTES ──────────────────────────────────────────────────────────────────
echo "  Creating routes..."

cat > routes/web.php << 'ROUTES'
<?php
use App\Http\Controllers\AuthController;
use App\Http\Controllers\ProductController;
use App\Http\Controllers\ReviewController;
use App\Http\Controllers\OrderController;
use App\Http\Controllers\ProfileController;
use App\Http\Controllers\DashboardController;
use Illuminate\Support\Facades\Route;

// Public routes
Route::get('/', function () { return redirect('/products'); });
Route::get('/login', [AuthController::class, 'showLogin'])->name('login');
Route::post('/login', [AuthController::class, 'login']);       // VULN: No rate limiting
Route::get('/register', [AuthController::class, 'showRegister']);
Route::post('/register', [AuthController::class, 'register']);
Route::get('/logout', [AuthController::class, 'logout']);

// Product routes (public)
Route::get('/products', [ProductController::class, 'index']);
Route::get('/products/search', [ProductController::class, 'search']);   // VULN: SQLi
Route::get('/products/{id}', [ProductController::class, 'show']);

// Authenticated routes (no middleware enforcement — another vulnerability)
Route::post('/products/{id}/review', [ReviewController::class, 'store']);  // VULN: Stored XSS
Route::get('/dashboard', [DashboardController::class, 'index']);
Route::get('/orders', [OrderController::class, 'index']);
Route::get('/order/{id}', [OrderController::class, 'show']);              // VULN: IDOR
Route::post('/checkout', [OrderController::class, 'checkout']);           // VULN: Price manipulation
Route::get('/profile', [ProfileController::class, 'show']);
Route::post('/profile/upload-avatar', [ProfileController::class, 'uploadAvatar']);  // VULN: File upload
Route::get('/change-password', [AuthController::class, 'showChangePassword']);
Route::post('/change-password', [AuthController::class, 'changePassword']);        // VULN: No CSRF

// VULNERABILITY: Verbose error/debug info exposed
Route::get('/debug-info', function () {
    return response()->json([
        'php_version' => phpversion(),
        'laravel_version' => app()->version(),
        'db_host' => env('DB_HOST'),
        'db_name' => env('DB_DATABASE'),
        'app_key' => env('APP_KEY'),
        'debug' => env('APP_DEBUG'),
    ]);
});
ROUTES

# ─── BLADE TEMPLATES ────────────────────────────────────────────────────────
echo "  Creating Blade templates..."

mkdir -p resources/views/{auth,products,orders,profile,layouts}

# Main layout
cat > resources/views/layouts/app.blade.php << 'BLADE'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VulnShop - @yield('title', 'Home')</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f5f5f5; color: #333; }
        .navbar { background: #1a1a2e; color: white; padding: 15px 30px; display: flex; justify-content: space-between; align-items: center; }
        .navbar a { color: #eee; text-decoration: none; margin: 0 15px; }
        .navbar a:hover { color: #e94560; }
        .navbar .brand { font-size: 1.4em; font-weight: bold; color: #e94560; }
        .container { max-width: 1100px; margin: 30px auto; padding: 0 20px; }
        .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .btn { display: inline-block; padding: 10px 20px; background: #e94560; color: white; border: none; border-radius: 5px; cursor: pointer; text-decoration: none; font-size: 0.95em; }
        .btn:hover { background: #c73e54; }
        .btn-secondary { background: #16213e; }
        input, textarea, select { width: 100%; padding: 10px; margin: 8px 0 16px 0; border: 1px solid #ddd; border-radius: 5px; font-size: 0.95em; }
        .alert { padding: 12px 20px; border-radius: 5px; margin-bottom: 15px; }
        .alert-success { background: #d4edda; color: #155724; border: 1px solid #c3e6cb; }
        .alert-error { background: #f8d7da; color: #721c24; border: 1px solid #f5c6cb; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 10px 15px; text-align: left; border-bottom: 1px solid #eee; }
        th { background: #1a1a2e; color: white; }
        .search-bar { display: flex; gap: 10px; margin-bottom: 20px; }
        .search-bar input { flex: 1; }
        .tag { display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 0.8em; }
        .tag-danger { background: #f8d7da; color: #721c24; }
        .tag-success { background: #d4edda; color: #155724; }
        .tag-warning { background: #fff3cd; color: #856404; }
        footer { text-align: center; padding: 20px; color: #888; font-size: 0.85em; margin-top: 40px; }
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

    <!-- VULNERABILITY: Server version info in footer -->
    <footer>
        VulnShop v1.0 | Powered by Laravel {{ app()->version() }} | PHP {{ phpversion() }}
        | Server: {{ $_SERVER['SERVER_SOFTWARE'] ?? 'Unknown' }}
    </footer>
</body>
</html>
BLADE

# Login page
cat > resources/views/auth/login.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Login')
@section('content')
<div class="card" style="max-width:400px; margin:40px auto;">
    <h2>Login</h2><br>
    <form method="POST" action="/login">
        @csrf
        <label>Email</label>
        <input type="email" name="email" required>
        <label>Password</label>
        <input type="password" name="password" required>
        <button type="submit" class="btn" style="width:100%;">Login</button>
    </form>
    <p style="margin-top:15px; text-align:center;">
        Don't have an account? <a href="/register">Register</a>
    </p>
</div>
@endsection
BLADE

# Register page
cat > resources/views/auth/register.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Register')
@section('content')
<div class="card" style="max-width:400px; margin:40px auto;">
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
BLADE

# Change password page
cat > resources/views/auth/change-password.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Change Password')
@section('content')
<div class="card" style="max-width:400px; margin:40px auto;">
    <h2>Change Password</h2><br>
    <!-- VULNERABILITY: No CSRF token in this form -->
    <form method="POST" action="/change-password">
        <label>New Password</label>
        <input type="password" name="new_password" required>
        <label>Confirm Password</label>
        <input type="password" name="confirm_password" required>
        <button type="submit" class="btn" style="width:100%;">Change Password</button>
    </form>
</div>
@endsection
BLADE

# Dashboard
cat > resources/views/dashboard.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Dashboard')
@section('content')
<h2>Welcome, {{ session('user_name') }}!</h2><br>
<div class="grid">
    <div class="card">
        <h3>Recent Orders</h3><br>
        @if(count($orders) > 0)
            <table>
                <tr><th>Order #</th><th>Total</th><th>Status</th></tr>
                @foreach($orders as $order)
                <tr>
                    <td><a href="/order/{{ $order->id }}">#{{ $order->id }}</a></td>
                    <td>₹{{ number_format($order->total, 2) }}</td>
                    <td><span class="tag tag-warning">{{ $order->status }}</span></td>
                </tr>
                @endforeach
            </table>
        @else
            <p>No orders yet.</p>
        @endif
    </div>
    <div class="card">
        <h3>Quick Links</h3><br>
        <p><a href="/products" class="btn">Browse Products</a></p><br>
        <p><a href="/profile" class="btn btn-secondary">Edit Profile</a></p><br>
        <p><a href="/change-password" class="btn btn-secondary">Change Password</a></p>
    </div>
</div>
@endsection
BLADE

# Products listing
cat > resources/views/products/index.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Products')
@section('content')
<h2>Products</h2><br>
<form action="/products/search" method="GET" class="search-bar">
    <input type="text" name="q" placeholder="Search products..." value="{{ request('q') }}">
    <button type="submit" class="btn">Search</button>
</form>
<div class="grid">
    @foreach($products as $product)
    <div class="card">
        <h3>{{ $product->name }}</h3>
        <p style="color:#888; margin:8px 0;">{{ Str::limit($product->description, 100) }}</p>
        <p style="font-size:1.3em; font-weight:bold; color:#e94560;">₹{{ number_format($product->price, 2) }}</p>
        <br>
        <a href="/products/{{ $product->id }}" class="btn">View Details</a>
    </div>
    @endforeach
</div>
@endsection
BLADE

# Product search results
cat > resources/views/products/search.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Search Results')
@section('content')
<h2>Search Results for "{{ $query }}"</h2><br>
<form action="/products/search" method="GET" class="search-bar">
    <input type="text" name="q" placeholder="Search products..." value="{{ $query }}">
    <button type="submit" class="btn">Search</button>
</form>
@if(count($products) > 0)
<div class="grid">
    @foreach($products as $product)
    <div class="card">
        <h3>{{ $product->name }}</h3>
        <p style="color:#888; margin:8px 0;">{{ Str::limit($product->description ?? '', 100) }}</p>
        <p style="font-size:1.3em; font-weight:bold; color:#e94560;">₹{{ number_format($product->price ?? 0, 2) }}</p>
        <br>
        <a href="/products/{{ $product->id }}" class="btn">View Details</a>
    </div>
    @endforeach
</div>
@else
<div class="card"><p>No products found matching "{{ $query }}".</p></div>
@endif
@endsection
BLADE

# Product detail page with reviews
cat > resources/views/products/show.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', $product->name)
@section('content')
<div class="card">
    <h2>{{ $product->name }}</h2>
    <p style="margin:15px 0;">{{ $product->description }}</p>
    <p style="font-size:1.5em; font-weight:bold; color:#e94560;">₹{{ number_format($product->price, 2) }}</p>
    <p style="color:#888;">Stock: {{ $product->stock }} available</p>
    <br>
    @if(session('user_id'))
    <form method="POST" action="/checkout">
        @csrf
        <input type="hidden" name="items[0][product_id]" value="{{ $product->id }}">
        <input type="hidden" name="items[0][quantity]" value="1">
        <!-- VULNERABILITY: Price sent from client side -->
        <input type="hidden" name="items[0][price]" value="{{ $product->price }}">
        <input type="hidden" name="total" value="{{ $product->price }}">
        <input type="text" name="shipping_name" placeholder="Your Name" required>
        <input type="text" name="shipping_address" placeholder="Shipping Address" required>
        <input type="text" name="phone" placeholder="Phone Number" required>
        <button type="submit" class="btn">Buy Now</button>
    </form>
    @else
    <p><a href="/login" class="btn">Login to Purchase</a></p>
    @endif
</div>

<div class="card">
    <h3>Customer Reviews</h3><br>
    @foreach($product->reviews as $review)
    <div style="padding:10px 0; border-bottom:1px solid #eee;">
        <strong>{{ $review->user->name ?? 'Anonymous' }}</strong>
        <span style="color:#e94560;">★ {{ $review->rating }}/5</span>
        <span style="color:#888; font-size:0.85em;">{{ $review->created_at->diffForHumans() }}</span>
        <!-- VULNERABILITY: Stored XSS — unescaped output -->
        <p style="margin-top:5px;">{!! $review->comment !!}</p>
    </div>
    @endforeach

    @if(session('user_id'))
    <br>
    <h4>Write a Review</h4>
    <form method="POST" action="/products/{{ $product->id }}/review">
        @csrf
        <select name="rating">
            <option value="5">★★★★★ (5)</option>
            <option value="4">★★★★ (4)</option>
            <option value="3">★★★ (3)</option>
            <option value="2">★★ (2)</option>
            <option value="1">★ (1)</option>
        </select>
        <textarea name="comment" rows="3" placeholder="Write your review..." required></textarea>
        <button type="submit" class="btn">Submit Review</button>
    </form>
    @endif
</div>
@endsection
BLADE

# Orders list
cat > resources/views/orders/index.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'My Orders')
@section('content')
<h2>My Orders</h2><br>
@if(count($orders) > 0)
<div class="card">
    <table>
        <tr><th>Order #</th><th>Date</th><th>Total</th><th>Status</th><th>Action</th></tr>
        @foreach($orders as $order)
        <tr>
            <td>#{{ $order->id }}</td>
            <td>{{ $order->created_at->format('d M Y') }}</td>
            <td>₹{{ number_format($order->total, 2) }}</td>
            <td><span class="tag tag-warning">{{ $order->status }}</span></td>
            <!-- VULNERABILITY: Any user can access any order URL -->
            <td><a href="/order/{{ $order->id }}" class="btn" style="padding:5px 12px; font-size:0.85em;">View</a></td>
        </tr>
        @endforeach
    </table>
</div>
@else
<div class="card"><p>No orders yet. <a href="/products">Browse products</a></p></div>
@endif
@endsection
BLADE

# Order detail (IDOR target)
cat > resources/views/orders/show.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Order Details')
@section('content')
<div class="card">
    <h2>Order #{{ $order->id }}</h2>
    <p><strong>Date:</strong> {{ $order->created_at->format('d M Y H:i') }}</p>
    <p><strong>Status:</strong> <span class="tag tag-warning">{{ $order->status }}</span></p>
    <p><strong>Ship to:</strong> {{ $order->shipping_name }}</p>
    <p><strong>Address:</strong> {{ $order->shipping_address }}</p>
    <p><strong>Phone:</strong> {{ $order->phone }}</p>
    <br>
    <table>
        <tr><th>Product</th><th>Qty</th><th>Price</th><th>Subtotal</th></tr>
        @foreach($order->items as $item)
        <tr>
            <td>{{ $item->product->name ?? 'N/A' }}</td>
            <td>{{ $item->quantity }}</td>
            <td>₹{{ number_format($item->price, 2) }}</td>
            <td>₹{{ number_format($item->price * $item->quantity, 2) }}</td>
        </tr>
        @endforeach
    </table>
    <br>
    <p style="font-size:1.3em; text-align:right;"><strong>Total: ₹{{ number_format($order->total, 2) }}</strong></p>
</div>
@endsection
BLADE

# Profile page
cat > resources/views/profile/show.blade.php << 'BLADE'
@extends('layouts.app')
@section('title', 'Profile')
@section('content')
<div class="card" style="max-width:500px;">
    <h2>Profile</h2><br>
    @if($user->avatar)
        <img src="{{ $user->avatar }}" alt="Avatar" style="width:100px; height:100px; border-radius:50%; object-fit:cover;">
        <br><br>
    @endif
    <p><strong>Name:</strong> {{ $user->name }}</p>
    <p><strong>Email:</strong> {{ $user->email }}</p>
    <p><strong>Role:</strong> {{ $user->role }}</p>
    <p><strong>Joined:</strong> {{ $user->created_at->format('d M Y') }}</p>
    <br>
    <h4>Upload Avatar</h4>
    <!-- VULNERABILITY: Insecure file upload -->
    <form method="POST" action="/profile/upload-avatar" enctype="multipart/form-data">
        @csrf
        <input type="file" name="avatar" required>
        <button type="submit" class="btn">Upload</button>
    </form>
</div>
@endsection
BLADE

# ─── DATABASE SEEDER ─────────────────────────────────────────────────────────
echo "  Creating database seeder..."

cat > database/seeders/DatabaseSeeder.php << 'SEEDER'
<?php
namespace Database\Seeders;

use Illuminate\Database\Seeder;
use App\Models\User;
use App\Models\Product;
use App\Models\Order;
use App\Models\OrderItem;
use App\Models\Review;

class DatabaseSeeder extends Seeder
{
    public function run(): void
    {
        // Create admin user
        User::create([
            'name' => 'Admin',
            'email' => 'admin@vulnshop.local',
            'password' => 'admin123',
            'role' => 'admin',
        ]);

        // Create test users
        $user1 = User::create([
            'name' => 'Alice Johnson',
            'email' => 'alice@example.com',
            'password' => 'password123',
            'role' => 'customer',
        ]);

        $user2 = User::create([
            'name' => 'Bob Smith',
            'email' => 'bob@example.com',
            'password' => 'password123',
            'role' => 'customer',
        ]);

        // Create products
        $products = [
            ['name' => 'Wireless Bluetooth Headphones', 'description' => 'Premium noise-cancelling over-ear headphones with 30-hour battery life, deep bass, and crystal-clear sound. Perfect for music lovers and professionals.', 'price' => 4999.00, 'stock' => 50],
            ['name' => 'Smart Fitness Tracker Pro', 'description' => 'Advanced fitness band with heart rate monitoring, SpO2 sensor, GPS tracking, sleep analysis, and 14-day battery life. Water resistant to 50m.', 'price' => 3499.00, 'stock' => 120],
            ['name' => 'Mechanical Gaming Keyboard', 'description' => 'RGB backlit mechanical keyboard with Cherry MX Blue switches, programmable macro keys, and aircraft-grade aluminum body.', 'price' => 7999.00, 'stock' => 35],
            ['name' => 'Ultra-Slim Laptop Stand', 'description' => 'Ergonomic aluminum laptop stand with adjustable height and angle. Improves posture and airflow. Foldable for portability.', 'price' => 1999.00, 'stock' => 200],
            ['name' => '4K Webcam with Ring Light', 'description' => 'Professional 4K webcam with built-in ring light, auto-focus, noise-cancelling dual microphones. Perfect for video calls and streaming.', 'price' => 5999.00, 'stock' => 65],
            ['name' => 'Portable SSD 1TB', 'description' => 'Ultra-fast portable SSD with USB-C, 1050MB/s read speed, 256-bit AES encryption, shock-resistant aluminum shell.', 'price' => 8499.00, 'stock' => 80],
            ['name' => 'Smart Home Security Camera', 'description' => '1080p WiFi security camera with night vision, two-way audio, motion detection alerts, and cloud storage. Works with Alexa.', 'price' => 2999.00, 'stock' => 150],
            ['name' => 'Wireless Charging Pad', 'description' => '15W fast wireless charging pad compatible with all Qi-enabled devices. Slim design with LED indicator and anti-slip surface.', 'price' => 1499.00, 'stock' => 300],
        ];

        foreach ($products as $p) {
            Product::create($p);
        }

        // Create sample order for Alice
        $order = Order::create([
            'user_id' => $user1->id,
            'shipping_name' => 'Alice Johnson',
            'shipping_address' => '123 Tech Street, Bangalore, KA 560001',
            'phone' => '+91 9876543210',
            'total' => 12498.00,
            'status' => 'pending',
        ]);

        OrderItem::create(['order_id' => $order->id, 'product_id' => 1, 'quantity' => 1, 'price' => 4999.00]);
        OrderItem::create(['order_id' => $order->id, 'product_id' => 4, 'quantity' => 1, 'price' => 1999.00]);
        OrderItem::create(['order_id' => $order->id, 'product_id' => 6, 'quantity' => 1, 'price' => 8499.00]);

        // Create sample order for Bob (IDOR target)
        $order2 = Order::create([
            'user_id' => $user2->id,
            'shipping_name' => 'Bob Smith',
            'shipping_address' => '456 Cyber Lane, Mumbai, MH 400001',
            'phone' => '+91 9123456789',
            'total' => 7999.00,
            'status' => 'shipped',
        ]);

        OrderItem::create(['order_id' => $order2->id, 'product_id' => 3, 'quantity' => 1, 'price' => 7999.00]);

        // Create sample reviews
        Review::create(['product_id' => 1, 'user_id' => $user1->id, 'rating' => 5, 'comment' => 'Amazing sound quality! Best headphones I have ever used.']);
        Review::create(['product_id' => 1, 'user_id' => $user2->id, 'rating' => 4, 'comment' => 'Great bass, but a bit heavy for long sessions.']);
        Review::create(['product_id' => 3, 'user_id' => $user2->id, 'rating' => 5, 'comment' => 'Cherry MX Blues are so satisfying. Build quality is top notch.']);
        Review::create(['product_id' => 6, 'user_id' => $user1->id, 'rating' => 5, 'comment' => 'Incredibly fast transfers. Worth every rupee.']);
    }
}
SEEDER

# ─── ENSURE UPLOADS DIRECTORY EXISTS ─────────────────────────────────────────
mkdir -p /var/www/html/vulnshop/public/uploads/avatars
chmod -R 777 /var/www/html/vulnshop/public/uploads

# ─── INTENTIONALLY COMMIT .env TO GIT (Vulnerability) ───────────────────────
echo "  Setting up git repo with .env exposed (intentional vulnerability)..."

cd /var/www/html/vulnshop

# Remove .env from .gitignore (vulnerability: exposing secrets)
sed -i '/^\.env$/d' .gitignore 2>/dev/null || true

git config --global user.email "lab@lab.local" 2>/dev/null || true
git config --global user.name "Lab Setup" 2>/dev/null || true
git init 2>/dev/null || true
git add -A 2>/dev/null || true
git commit -m "Initial commit - VulnShop v1.0" 2>/dev/null || true

# ─── RUN MIGRATIONS AND SEED ────────────────────────────────────────────────
echo "  Running database migrations..."

cd /var/www/html/vulnshop
php artisan migrate --force 2>&1
php artisan db:seed --force 2>&1

echo "  Database migrated and seeded."

# ─── SET PERMISSIONS ─────────────────────────────────────────────────────────
chown -R www-data:www-data /var/www/html/vulnshop
chmod -R 755 /var/www/html/vulnshop
chmod -R 777 /var/www/html/vulnshop/storage
chmod -R 777 /var/www/html/vulnshop/bootstrap/cache
chmod -R 777 /var/www/html/vulnshop/public/uploads

# ─── STEP 9: CONFIGURE APACHE VIRTUAL HOSTS ─────────────────────────────────
echo ""
echo "[STEP 9/12] Configuring Apache virtual hosts..."

# DVWA on port 80 (default)
cat > /etc/apache2/sites-available/000-default.conf << 'VHOST'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html

    # DVWA accessible at http://<ip>/dvwa/
    <Directory /var/www/html/dvwa>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined

    # VULNERABILITY: Server signature exposed
    ServerSignature On
</VirtualHost>
VHOST

# VulnShop on port 8080
cat > /etc/apache2/sites-available/vulnshop.conf << 'VHOST'
Listen 8080
<VirtualHost *:8080>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/html/vulnshop/public

    <Directory /var/www/html/vulnshop/public>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/vulnshop-error.log
    CustomLog ${APACHE_LOG_DIR}/vulnshop-access.log combined

    # VULNERABILITY: No security headers configured
    # Missing: X-Content-Type-Options, X-Frame-Options, CSP, etc.

    # VULNERABILITY: Server signature exposed
    ServerSignature On
</VirtualHost>
VHOST

a2ensite vulnshop.conf
a2enmod rewrite

# ─── STEP 10: CONFIGURE PHP (INTENTIONALLY WEAK) ────────────────────────────
echo ""
echo "[STEP 10/12] Configuring PHP (intentionally weak settings)..."

PHP_INI=$(find /etc/php -name "php.ini" -path "*/apache2/*" | head -1)
if [ -n "$PHP_INI" ]; then
  # VULNERABILITY: Expose PHP version
  sed -i 's/^expose_php = .*/expose_php = On/' "$PHP_INI"
  # VULNERABILITY: Display errors in production
  sed -i 's/^display_errors = .*/display_errors = On/' "$PHP_INI"
  sed -i 's/^display_startup_errors = .*/display_startup_errors = On/' "$PHP_INI"
  # Allow URL file operations (needed for some DVWA labs)
  sed -i 's/^allow_url_include = .*/allow_url_include = On/' "$PHP_INI"
  sed -i 's/^allow_url_fopen = .*/allow_url_fopen = On/' "$PHP_INI"
  # Generous upload limit
  sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 20M/' "$PHP_INI"
  sed -i 's/^post_max_size = .*/post_max_size = 25M/' "$PHP_INI"
fi

echo "  PHP configured with intentionally weak security settings."

# ─── STEP 11: FIREWALL ──────────────────────────────────────────────────────
echo ""
echo "[STEP 11/12] Configuring firewall..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp comment "Apache HTTP (DVWA)"
ufw allow 8080/tcp comment "VulnShop"
ufw allow 3306/tcp comment "MySQL (intentionally exposed)"
ufw --force enable

echo "  Firewall configured: SSH + TCP 80, 8080, 3306"

# ─── STEP 12: HOSTS FILE, HELPERS, FINALIZE ──────────────────────────────────
echo ""
echo "[STEP 12/12] Finalizing setup..."

add_hosts_entry() {
  local IP="$1"; local ALIASES="$2"
  [ -n "$IP" ] && ! grep -q "$IP" /etc/hosts && echo "$IP   $ALIASES" >> /etc/hosts
}
echo "" >> /etc/hosts
echo "# AppSec Lab Environment" >> /etc/hosts
add_hosts_entry "$VM01_IP" "vm01 sonarqube-server"
add_hosts_entry "$VM02_IP" "vm02 zap-server nessus-server"
add_hosts_entry "$VM03_IP" "vm03 target-server"

# Create helper scripts
mkdir -p "$LAB_HOME/scripts"

cat > "$LAB_HOME/scripts/check-status.sh" << 'SCRIPT'
#!/bin/bash
echo "=== VM-03 Service Status ==="
echo ""
echo "--- Apache ---"
systemctl is-active apache2 && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
echo "--- MySQL ---"
systemctl is-active mariadb && echo "Status: RUNNING" || echo "Status: STOPPED"
echo ""
echo "--- DVWA ---"
curl -sf -o /dev/null http://localhost/dvwa/login.php && echo "[OK] DVWA: http://$(hostname -I | awk '{print $1}')/dvwa/" || echo "[FAIL] DVWA not responding"
echo ""
echo "--- VulnShop ---"
curl -sf -o /dev/null http://localhost:8080 && echo "[OK] VulnShop: http://$(hostname -I | awk '{print $1}'):8080" || echo "[FAIL] VulnShop not responding"
echo ""
echo "--- Disk / Memory ---"
df -h / | tail -1 | awk '{print "Disk: " $3 " / " $2 " (" $5 ")"}'
free -h | grep Mem | awk '{print "RAM:  " $3 " / " $2}'
SCRIPT

cat > "$LAB_HOME/scripts/reset-dvwa-db.sh" << 'SCRIPT'
#!/bin/bash
echo "Resetting DVWA database..."
curl -sf -b "security=low; PHPSESSID=dummy" \
  "http://localhost/dvwa/setup.php" > /dev/null
echo "Visit http://localhost/dvwa/setup.php and click 'Create / Reset Database'"
SCRIPT

cat > "$LAB_HOME/scripts/reset-vulnshop.sh" << 'SCRIPT'
#!/bin/bash
echo "Resetting VulnShop database..."
cd /var/www/html/vulnshop
sudo php artisan migrate:fresh --seed --force
echo "VulnShop database reset complete!"
echo ""
echo "Test accounts:"
echo "  Admin: admin@vulnshop.local / admin123"
echo "  Alice: alice@example.com / password123"
echo "  Bob:   bob@example.com / password123"
SCRIPT

chmod +x "$LAB_HOME/scripts/"*.sh
chown -R "$LAB_USER:$LAB_USER" "$LAB_HOME/scripts"

# ─── MOTD ────────────────────────────────────────────────────────────────────
cat > /etc/motd << 'EOF'

 ╔══════════════════════════════════════════════════════════════╗
 ║  VM-03: Vulnerable Target Server                            ║
 ║  Application Security Testing — SAST & DAST Lab             ║
 ║  Sarath G | www.sarathg.me                                  ║
 ╠══════════════════════════════════════════════════════════════╣
 ║                                                              ║
 ║  DVWA:      http://<this-ip>/dvwa/                          ║
 ║             Login: admin / password                         ║
 ║                                                              ║
 ║  VulnShop:  http://<this-ip>:8080                           ║
 ║             Admin:  admin@vulnshop.local / admin123         ║
 ║             Alice:  alice@example.com / password123         ║
 ║             Bob:    bob@example.com / password123           ║
 ║                                                              ║
 ║  Helper scripts:  ~/scripts/check-status.sh                ║
 ║                   ~/scripts/reset-dvwa-db.sh               ║
 ║                   ~/scripts/reset-vulnshop.sh              ║
 ║                                                              ║
 ║  ⚠  THIS IS A DELIBERATELY VULNERABLE SERVER               ║
 ║     DO NOT EXPOSE TO PRODUCTION NETWORKS                    ║
 ║                                                              ║
 ╚══════════════════════════════════════════════════════════════╝

EOF

# ─── RESTART SERVICES ────────────────────────────────────────────────────────
echo ""
echo "Restarting Apache..."
systemctl restart apache2

# Initialize DVWA database via curl
echo "Initializing DVWA database..."
sleep 2
curl -sf -d "create_db=Create+/+Reset+Database" \
  "http://localhost/dvwa/setup.php" > /dev/null 2>&1 || echo "  (Visit /dvwa/setup.php manually to initialize DB)"

# ─── CLEANUP ─────────────────────────────────────────────────────────────────
echo ""
echo "Cleaning up..."
apt-get autoremove -y -qq
apt-get clean

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo ""
echo "======================================================================"
echo " VM-03 SETUP COMPLETE"
echo "======================================================================"
echo ""
echo " DVWA:              http://$THIS_IP/dvwa/"
echo "   Login:           admin / password"
echo "   Security Level:  Low (default)"
echo ""
echo " VulnShop:          http://$THIS_IP:8080"
echo "   Admin:           admin@vulnshop.local / admin123"
echo "   Test User 1:     alice@example.com / password123"
echo "   Test User 2:     bob@example.com / password123"
echo ""
echo " Intentional Vulnerabilities in VulnShop:"
echo "   1. SQL Injection       - /products/search?q="
echo "   2. Stored XSS          - Product reviews"
echo "   3. IDOR                - /order/{id}"
echo "   4. CSRF bypass         - /change-password"
echo "   5. Weak crypto (MD5)   - Password hashing"
echo "   6. Hardcoded creds     - .env in git repo"
echo "   7. Debug mode on       - APP_DEBUG=true"
echo "   8. Insecure upload     - /profile/upload-avatar"
echo "   9. No rate limiting    - /login"
echo "  10. Info disclosure     - /debug-info, footer, PHP headers"
echo ""
echo " MySQL exposed:     Port 3306 (intentionally for Nessus to detect)"
echo " Lab User:          $LAB_USER (home: $LAB_HOME)"
echo " Log File:          $LOG_FILE"
echo ""
echo " Completed: $(date)"
echo "======================================================================"
