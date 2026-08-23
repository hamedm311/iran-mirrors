# HostBaran Mirror Manager

ابزار خط فرمان امن برای شناسایی و تبدیل Repositoryهای رسمی Ubuntu و AlmaLinux به Mirrorهای ایران. نسخه اول فقط منابع رسمی سیستم‌عامل و Ruleهای مشخص EPEL و MariaDB را بررسی می‌کند؛ Repositoryهای شخصی، داخلی، Third-party و ناشناخته بدون تغییر باقی می‌مانند.

## نصب سریع

برای اجرای مستقیم آخرین نسخه از GitHub:

```bash
bash <(curl -Ls --ipv4 https://raw.githubusercontent.com/hamedm311/iran-mirrors/main/mirror-manager.sh)
```

یا برای نصب محلی از مخزن GitHub:

```bash
git clone https://github.com/hamedm311/iran-mirrors.git
cd iran-mirrors
chmod +x mirror-manager.sh
sudo bash mirror-manager.sh
```

دستور اجرای مستقیم، تنظیمات پیش‌فرض Mirrorها را داخل خود اسکریپت دارد و به Clone کردن پروژه نیاز ندارد.

## سیستم‌عامل‌های پشتیبانی‌شده

| سیستم‌عامل | نسخه‌ها |
|---|---|
| Ubuntu | 20.04، 22.04، 24.04، 26.04 |
| AlmaLinux | 8، 9، 10 |

تشخیص بر اساس `/etc/os-release` و نسخه دقیق انجام می‌شود، نه فقط نام سیستم‌عامل.

## Mirrorها

| Repository | Mirror |
|---|---|
| Ubuntu | `https://ir.archive.ubuntu.com` |
| AlmaLinux | `https://mirror.hostbaran.com/almalinux` |
| EPEL | `https://mirror.hostbaran.com/epel` |
| MariaDB | `https://mirror.hostbaran.com/mariadb` |
| CloudLinux | `https://mirror.hostbaran.com/cloudlinux` |

تنظیمات در `config/mirrors.conf` متمرکز است. CloudLinux در این نسخه فقط به‌عنوان مقصد آینده تعریف شده و بدون Rule رسمی تغییر نمی‌کند.

## نصب و اجرای محلی

این پروژه نصب پیچیده‌ای ندارد:

```bash
chmod +x mirror-manager.sh
sudo bash mirror-manager.sh
```

اجرای واقعی Root، Backup قبل از تغییر، تغییر اتمیک و بررسی نهایی را انجام می‌دهد. برای Ubuntu فایل‌های `sources.list` و `.list`/`.sources` و برای AlmaLinux فایل‌های `.repo` بررسی می‌شوند.

## حالت‌ها

```bash
sudo bash mirror-manager.sh --dry-run
sudo bash mirror-manager.sh --verbose
sudo bash mirror-manager.sh --yes --no-update
sudo bash mirror-manager.sh --rollback
sudo bash mirror-manager.sh --rollback-on-error
sudo bash mirror-manager.sh --json --no-update
```

`--dry-run` هیچ فایلی را تغییر نمی‌دهد. `--no-update` اجرای `apt-get update` یا `dnf makecache` را حذف می‌کند. `--quiet` فقط Summary را نشان می‌دهد و `--no-color` برای محیط‌های بدون ANSI است.

## روند ایمن تغییر

1. بررسی Root، Bash و وابستگی‌ها
2. تشخیص OS، نسخه، Codename، Kernel و Architecture
3. تشخیص و Classification منابع واقعی
4. تست ساختار مقصد و تهیه Backup هنگام تغییر واقعی
5. بازنویسی temporary و جایگزینی اتمیک
6. حفظ مالکیت و Permission
7. اعتبارسنجی و در صورت درخواست Refresh Metadata
8. گزارش نتیجه هر فایل و Summary

`mirrorlist` و `metalink` فقط در Repositoryهای شناخته‌شده comment می‌شوند و `gpgcheck` یا اعتبارسنجی امضای APT غیرفعال نمی‌شود.

## Backup و Rollback

Backupها در مسیر زیر نگهداری می‌شوند:

```text
/var/backups/mirror-manager/YYYY-MM-DD_HH-MM-SS/
```

هر Session شامل `manifest.txt` و نسخه اصلی فایل‌ها است. آخرین Backup با دستور زیر بازگردانده می‌شود:

```bash
sudo bash mirror-manager.sh --rollback
```

Backup فقط برای فایل‌هایی ساخته می‌شود که واقعاً تغییر می‌کنند؛ Symlink به‌عنوان منبع Backup پذیرفته نمی‌شود.

## نمونه قبل و بعد AlmaLinux

قبل:

```ini
[baseos]
mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos
enabled=1
```

بعد:

```ini
[baseos]
# mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos
baseurl=https://mirror.hostbaran.com/almalinux/$releasever/BaseOS/$basearch/os/
enabled=1
```

## فایل‌های پروژه

- `mirror-manager.sh`: هسته self-contained و CLI
- `config/mirrors.conf`: لایه تنظیم Mirrorها
- `tests/test_syntax.sh`: آزمون syntax و CLI
- `tests/test_transformations.sh`: آزمون تبدیل و عدم تغییر منابع غیرهدف
- `VERSION`: نسخه انتشار
- `LICENSE`: مجوز MIT

## فایل‌هایی که تغییر نمی‌کنند

در Ubuntu، دامنه‌هایی مانند Docker، Microsoft، HashiCorp و PPAها هدف نیستند. در AlmaLinux نیز Repository داخلی، URL سفارشی، شناسه ناشناخته و Repository غیرفعال تغییر نمی‌کنند. ابزار فایل خارج از `/etc/apt` و `/etc/yum.repos.d` را مدیریت نمی‌کند.

## Exit Codeها

| کد | معنا |
|---:|---|
| 0 | موفقیت کامل یا بدون نیاز به تغییر |
| 1 | خطای عمومی |
| 2 | سیستم‌عامل پشتیبانی‌نشده |
| 3 | دسترسی Root وجود ندارد |
| 4 | خطای Validation یا Metadata |
| 5 | موفقیت ناقص |
| 6 | شکست Rollback |

## تست

روی Linux یا WSL دارای Bash اجرا کنید:

```bash
bash tests/test_syntax.sh
bash tests/test_transformations.sh
```

تست‌ها به فایل‌های واقعی سیستم دست نمی‌زنند. تست کامل `apt-get update`/`dnf makecache` نیازمند ماشین مجازی یا Container همان Distribution و دسترسی شبکه است.

## عیب‌یابی

- `Missing dependency`: وابستگی اعلام‌شده را با Package Manager همان سیستم نصب کنید.
- `Unsupported Operating System`: نسخه سیستم در فهرست بالا نیست و هیچ تغییری انجام نشده است.
- `Mirror unreachable`: با `curl -fsSI` دسترسی DNS، HTTPS و مسیر مقصد را بررسی کنید.
- `Validation failure`: Backup را نگه دارید و در صورت نیاز `--rollback` اجرا کنید.
- خطای قفل: اجرای هم‌زمان دیگری با `mirror-manager.sh` در حال انجام است.

## مشارکت

برای افزودن Distribution یا Mirror جدید، ابتدا Rule طبقه‌بندی، Builder مسیر، آزمون fixture و مستندات همان Rule را اضافه کنید. جایگزینی عمومی URL بدون Classification قابل قبول نیست.
