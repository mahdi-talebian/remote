# مدیریت از راه دور کامپیوترهای کارمندان — با SSH و Tailscale

این پکیج یک راه‌حل **بدون نیاز به سرور** برای اتصال امن SSH به کامپیوترهای ویندوزی کارمندان است:

```
[کامپیوتر تو]  ──Tailscale (شبکه خصوصی)──>  [کامپیوتر کارمند: sshd + Tailscale]
      ssh it_remote@pc-01.nasir.ts.net
```

- ❌ بدون نیاز به IP عمومی، بدون باز کردن پورت روی اینترنت، بدون سرور واسط
- ✅ آدرس ثابت و قابل‌حمل: `ssh it_remote@pc-01.<tailnet>.ts.net` (همیشه یکی است)
- ✅ بعد از ری‌استارت کامپیوتر کارمند، خودکار دوباره وصل می‌شود (سرویس پس‌زمینه)
- ✅ احراز هویت با **رمز عبور** (طبق انتخاب شما)

> 📘 **راهنمای کامل Tailscale برای این طرح** (ساخت کلید، ACL، انقضای کلید دستگاه‌ها، عیب‌یابی): فایل **`tailscale-guide.md`** را در همین پوشه ببین.

---

## 🗂 فایل‌ها

| فایل | اجرا روی | کار |
|---|---|---|
| `deploy-employee.ps1` | **هر کامپیوتر کارمند** (یک‌بار، به‌عنوان Admin) | فعال‌سازی sshd، ساخت اکانت، نصب Tailscale، فایروال، چاپ آدرس SSH |
| `get-addresses.ps1` | **کامپیوتر خودت** | لیست همه کامپیوترها + آدرس‌های SSH، ذخیره در `ssh-addresses.txt` |
| `deploy-via-domain.ps1` | **کامپیوتر خودت** (اختیاری) | اجرای خودکار اسکریپت روی چند کامپیوتر از راه دور (WinRM/domain) |
| `gui/AdminConsole.ps1` (+ `.bat`) | **کامپیوتر خودت** | رابط گرافیکی مدیریت: لیست سیستم‌ها، وضعیت اتصال، اتصال با یک کلیک |
| `gui/SetupWizard.ps1` (+ `.bat`) | **هر کامپیوتر کارمند** | رابط گرافیکی استقرار: فرم ساده + لاگ زنده + نمایش آدرس SSH |

---

## 🖥 رابط گرافیکی (GUI)

بدون نیاز به نصب هیچ چیز — فقط PowerShell (روی همه ویندوزها موجود است). دو برنامه:

### کنسول مدیریت — `gui\AdminConsole.bat` (روی کامپیوتر خودت)

- دکمه **«به‌روزرسانی»**: دریافت لیست همه کامپیوترها با وضعیت **آنلاین/آفلاین** از Tailscale
- **دوبار کلیک** روی هر ردیف (یا دکمه «اتصال SSH»): باز شدن ترمینال SSH همان سیستم
- دکمه **«کپی آدرس»**، **«ذخیره لیست»** در فایل TXT، **جستجو**، **نمایش آفلاین‌ها**، تغییر نام کاربری (پیش‌فرض `it_remote`)
- دکمه **«ویزارد استقرار»**: باز کردن ویزارد روی همین کامپیوتر (برای تست)

```bat
:: اجرا
AdminConsole.bat        (دوبار کلیک)
```

### ویزارد استقرار — `gui\SetupWizard.bat` (روی هر کامپیوتر کارمند)

فرم ساده با فیلدهای: نام دستگاه + کلید Tailscale + رمز عبور و تکرار آن → دکمه **«شروع استقرار»**:

- لوگ زنده (لاگ زنده همان اسکریپت `deploy-employee.ps1` است، پس رفتار کاملاً یکسان است)
- نوار پیشرفت + در پایان، **آدرس SSH** نمایش داده می‌شود و با دکمه «کپی آدرس SSH» کپی می‌شود
- اگر با دسترسی Administrator اجرا نشود، خودش مجدداً با دسترسی Admin باز می‌کند

```bat
:: اجرا (روی هر کامپیوتر کارمند)
SetupWizard.bat         (دوبار کلیک - مدیر سیستم)
```

> 💡 برای توزیع آسان: فقط پوشه `gui` را (هر دو فایل `.bat` و `.ps1` کنار هم) به سیستم هدف کپی کنید.
> نکته فنی: فایل‌های `.ps1` با **UTF-8 BOM** ذخیره شده‌اند تا متن فارسی در PowerShell 5.1 درست نمایش داده شود.

---

## ✅ تست خودکار (E2E) — پکیج چگونه راستی‌آزمایی شد

پکیج شامل یک **تست‌سوئیت خودکار** است (`tests/run-e2e.ps1`) که کل چرخه را واقعی اجرا و راستی‌آزمایی می‌کند:

| بخش تست | واقعی / شبیه‌سازی |
|---|---|
| اجرای واقعی `deploy-employee.ps1` (اسکریپت، اکانت، رمز، آدرس) | ✅ واقعی (PowerShell واقعی، یوزر و chpasswd واقعی) |
| تولید آدرس در **tailnet ایمیلی** (مثل `user@gmail.com` → IP) | ✅ بازتولید دقیق سناریوی شما |
| تولید آدرس در tailnet عادی (`mycorp.ts.net` → DNS) | ✅ |
| دیدن همدیگر (agent ↔ admin) در tailnet | ✅ (نقش‌ها state مشترک دارند) |
| `get-addresses.ps1` از دید مدیر | ✅ اجرای واقعی |
| **ورود واقعی SSH با رمز** به آدرس تولیدشده | ✅ sshd + کلاینت OpenSSH واقعی |
| کلید اشتباه (آدرس ts.net به‌جای کلید) → شکست شفاف | ✅ |
| بازیابی آدرس در ویزارد + ساخت آدرس در کنسول | ✅ (توابع واقعی فایل‌های ارسالی) |

نتیجه‌ی آخرین اجرا: **۲۹/۲۹ پاس** (گزارش: `tests/REPORT.md`)
> فقط «سرویس ابری Tailscale» شبیه‌سازی می‌شود (امکانساز نیست در sandbox)؛
> این تست‌ها روی لینوکس اجرا می‌شوند و مسیرهای مخصوص ویندوز (WinForms، OpenSSH
> capability، فایروال) با پارسر و همان منطق قبلی تأیید شده‌اند.

---

## ⚙️ مرحله ۱ — آماده‌سازی روی کامپیوتر خودت (فقط یک‌بار)

1. **Tailscale** را نصب کن: https://tailscale.com/download/windows
2. با حساب گوگل/مایکروسافت لاگین کن (حساب تو، خودش `tailnet` برای شما می‌سازد).
3. یک **کلید احراز هویت (Auth Key)** بساز تا کارمندان بدون لاگین دستی به شبکه‌ات وصل شوند:
   - برو به [admin console](https://login.tailscale.com/admin/settings/keys) → **Generate auth key**
   - ✔️ گزینه **Reusable** را فعال کن (تا بتوانی از یک کلید برای همه کامپیوترها استفاده کنی)
   - مدت اعتبار را مثلاً ۹۰ روز بگذار و روی **Generate** بزن → چیزی مثل:
     `tskey-auth-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`

> 💡 **نکته امنیتی مهم:** پیشنهاد می‌شود در admin console، به این کلید «Tags» مثل `tag:employee-pc` بدهی و در تنظیمات **ACL** طوری بنویسی که فقط دستگاه‌های تو (نه کارمندان!) به هم دسترسی داشته باشند. نمونه ACL در انتهای همین فایل.

---

## 🖥 مرحله ۲ — استقرار روی یک کامپیوتر کارمند (تست)

1. پوشه `remote-admin` را (فقط `deploy-employee.ps1` کافی است) به کامپیوتر هدف منتقل کن (فلش/شبکه/ایمیل).
2. PowerShell را **به‌عنوان Administrator** باز کن و اجرا کن:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-employee.ps1 `
  -TailscaleAuthKey "tskey-auth-XXXX...." `
  -AdminPassword "یک-رمز-قوی-انتخاب-کن!" `
  -Hostname "pc-01"
```

3. در انتهای اجرا، آدرس SSH چاپ می‌شود و در `C:\ProgramData\RemoteAdmin\ssh-address.txt` هم ذخیره می‌شود:

```
REMOTE SSH ADDRESS  ->   ssh it_remote@pc-01.cool-tailnet.ts.net
```

> اگر اینترنت محدود باشد، Tailscale را دستی از `https://tailscale.com/download/windows` نصب کن و دوباره اسکریپت را اجرا کن (اسکریپت idempotent است؛ اجرای مجدد امن است).
> اگر `-Hostname` ندهی، نام کامپیوتر (COMPUTERNAME) به‌صورت خودکار استفاده می‌شود.

---

## 🔎 مرحله ۳ — گرفتن آدرس همه کامپیوترها (روی کامپیوتر خودت)

```powershell
powershell -ExecutionPolicy Bypass -File .\get-addresses.ps1
```

خروجی:

```
[ONLINE ] ssh it_remote@pc-01.cool-tailnet.ts.net
[ONLINE ] ssh it_remote@pc-02.cool-tailnet.ts.net
[OFFLINE] ssh it_remote@pc-03.cool-tailnet.ts.net
```

و فایل `ssh-addresses.txt` ساخته می‌شود.

---

## 🚀 مرحله ۴ — استقرار روی بقیه کارمندها

**روش الف) اسکریپت from-scratch:** هر کارمند از اسکریپت پذیرش کند (دقیقاً مثل مرحله ۲). ساده و شفاف.

**روش ب) از راه دور (اختیاری، نیاز به WinRM/دومین):**

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-via-domain.ps1 `
  -ComputerNames pc-01,pc-02,pc-03 `
  -TailscaleAuthKey "tskey-auth-XXXX" -AdminPassword "رمز-قوی"
```

> یا با PsExec (بدون WinRM): `psexec \\pc-01 -s -i powershell -ExecutionPolicy Bypass -File C:\deploy-employee.ps1 -TailscaleAuthKey ... -AdminPassword '...'` + فایل را قبلاً به `\\pc-01\C$\` کپی کن.

**روش ج) GPO در دامنه:** فایل را با GPO به `C:\ProgramData\RemoteAdmin\` توزیع کن و یک `Scheduled Task` (با اجرای `-TailscaleAuthKey ... -AdminPassword ...`) در بوت/لاگین، یک‌بار اجرا کن.

---

## 🔑 مرحله ۵ — اتصال

از کامپیوتر خودت (با Tailscale روشن):

```bash
ssh it_remote@pc-01.cool-tailnet.ts.net
```

رمز = همان `AdminPassword` که در مرحله ۲ دادی. اولین بار پیام امنیتی (fingerprint) را با `yes` تأیید کن.

### اتصال بدون رمز (اختیاری، امن‌تر)
روی کامپیوتر خودت یک‌بار:

```bash
ssh-keygen -t ed25519                                   # اگر کلید نداری
ssh-copy-id -i $HOME\.ssh\id_ed25519.pub it_remote@pc-01.cool-tailnet.ts.net
# ویندوز:  type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh it_remote@pc-01... "powershell -c \"Add-Content $env:ProgramData\ssh\administrators_authorized_keys -Value ([Console]::In.ReadToEnd())\""
```

---

## 🛡 نکات امنیتی (حتماً بخوان)

1. **رمز قوی** برای اکانت `it_remote` — حداقل ۱۴ کاراکتر ترکیبی؛ این همان درِ ورود به کل سیستم است.
2. با اضافه کردن نکته بالا در **ACL تیل‌اسکیل** مطمئن شو کارمندها به کامپیوتر همدیگر دسترسی ندارند و فقط دستگاه خودت به‌عنوان `admin` می‌تواند وصل شود.
3. اکانت `it_remote` روی هر سیستم **Administrator** است — مراقب انتقال رمز/فایل‌ها باش.
4. اسکریپت فایروال را طوری تنظیم می‌کند که پورت ۲۲ فقط روی **اینترفیس Tailscale** باز باشد، نه روی اینترنت. (اگر در شبکه‌ات interface نام دیگری دارد، به `InterfaceAlias` در خط فایروال توجه کن؛ در صورت شکست، به‌عنوان fallback روی همه اینترفیس‌ها باز می‌شود — بهترین حالت را اعمال کن.)
5. بهتر است Tailscale را روی کامپیوتر خودت **با فیلترهای ACL** محدود کنی (مثلاً فقط SSH به `tag:employee-pc`).
6. اگر کارمندی ناخواسته Tailscale را ببندد، فقط با کلید Auth Key یا دسترسی فیزیکی/دامنه قابل استقرار مجدد است؛ پس کلید را محرمانه نگه دار.

### نمونه ACL (در Tailscale Admin → Access Controls)
```json
{
  "tagOwners": { "tag:employee-pc": ["autogroup:admin"] },
  "acl": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["tag:employee-pc:22"] },
    { "action": "accept", "src": ["tag:employee-pc"],  "dst": ["tag:employee-pc:22"] }
  ]
}
```

---

## 🩺 عیب‌یابی

| مشکل | راه‌حل |
|---|---|
| `tailscale` پیدا نشد | Tailscale روی سیستم مقصد نصب نیست؛ دستی نصب و دوباره اجرا کن |
| آدرس `*.ts.net` کار نمی‌کند | `tailscale status` را بزن؛ آدرس IP 100.x را هم امتحان کن (فقط در tailnet خودت) |
| `Connection refused` | سرویس sshd روی مقصد خاموش است: `Get-Service sshd; Start-Service sshd` |
| `Permission denied` | رمز اشتباه؛ یا رمز را عوض کن: `Set-LocalUser it_remote -Password (Read-Host -AsSecureString)` |
| در tailnet فقط خودت هستی | auth key Reusable نبوده؛ کلید جدید بساز و دوباره `tailscale up` کن |
| ویندوز قدیمی (مثلاً 7/8) | OpenSSH سرور رسمی ندارد؛ از MobaSSH یا Bitvise استفاده کن |

---

## 🧹 حذف کامل یک کامپیوتر

```powershell
# روی ماشین کارمند (Admin):
Remove-LocalUser it_remote
Get-Service sshd | Stop-Service; Set-Service sshd -StartupType Disabled
& 'C:\Program Files\Tailscale\tailscale.exe' logout
# از کنسول Tailscale هم device را حذف کن
```
