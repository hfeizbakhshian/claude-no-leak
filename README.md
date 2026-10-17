# claude-no-leak

اجرای Claude Code روی لینوکس، مک و ویندوز، طوری که **هیچ درخواستی بدون پروکسی از سیستم خارج نشود**.

هر سناریو یک «کلید قطع» (kill switch) دارد: Claude فقط به پروکسی محلی دسترسی دارد و هر راه دیگری به اینترنت بسته است. اگر پروکسی خاموش باشد، یا IP خروجی‌اش در کشور مورد انتظار (پیش‌فرض: آلمان، `DE`) نباشد، Claude اصلاً اجرا نمی‌شود. وسط کار هم هر ۲ دقیقه کشور خروجی دوباره بررسی می‌شود و اگر عوض شده باشد، تونل قطع می‌شود.

| سیستم‌عامل | پوشه | کلید قطع | دسترسی لازم |
|---|---|---|---|
| لینوکس | `linux-native/` | فیلتر IP خودِ systemd (فقط loopback مجاز است) | یک بار `sudo` موقع نصب |
| مک | `mac-native/` | پروفایل Seatbelt با `sandbox-exec` | بدون نیاز به ادمین |
| ویندوز | `windows-native/` | قانون خروجی Windows Firewall برای فایل اجرایی Claude | PowerShell با دسترسی Administrator |
| داکر (قدیمی) | `docker/` | iptables داخل کانتینر | داکر |

---

## ۱. راه‌اندازی پروکسی (v2ray)

همه‌ی اسکریپت‌ها فرض می‌کنند یک پروکسی روی **`127.0.0.1:10808`** در حال اجراست. ساده‌ترین راه، یک کلاینت v2ray/Xray است که روی همین پورت گوش بدهد.

### کلاینت پیشنهادی

- **ویندوز:** [v2rayN](https://github.com/2dust/v2rayN/releases)
- **مک:** v2rayN (نسخه‌ی macOS از همان صفحه‌ی releases)، یا هر کلاینتی که پورت محلی SOCKS بدهد (V2Box، FoXray و …)
- **لینوکس:** v2rayN (نسخه‌ی لینوکس)، [v2rayA](https://github.com/v2rayA/v2rayA)، یا خودِ Xray-core با فایل کانفیگ (پایین‌تر)

### تنظیمات کلاینت

1. **کانفیگ سرور** (لینک `vless://` ، `vmess://` ، `trojan://` و …) را وارد کنید: در v2rayN از منوی *Servers → Import from clipboard*.
2. **سرور آلمان انتخاب کنید.** اسکریپت‌ها فقط با IP خروجی آلمان اجرا می‌شوند (برای کشور دیگر بخش «تنظیمات» را ببینید).
3. **پورت محلی را `10808` بگذارید.** در v2rayN: *Settings → Parameter settings → Local port (socks)*. پیش‌فرض v2rayN همین `10808` است و هم SOCKS5 و هم HTTP را روی آن جواب می‌دهد، که برای همه‌ی سناریوها لازم است.
4. **Routing را روی Global (همه از پروکسی) بگذارید.** حالت‌هایی مثل «Bypass Iran» برای Claude مشکلی ایجاد نمی‌کنند، ولی Global مطمئن‌تر است.
5. **«Allow connections from LAN» را خاموش نگه دارید**، مگر برای سناریوی داکر (پایین‌تر).
6. System proxy و TUN لازم نیستند؛ اسکریپت‌ها خودشان Claude را به پروکسی وصل می‌کنند.

### تست پروکسی

قبل از هر چیز، مطمئن شوید پروکسی کار می‌کند و خروجی‌اش آلمان است:

```bash
# لینوکس و مک
curl --socks5-hostname 127.0.0.1:10808 https://ipinfo.io/country
```

```powershell
# ویندوز
curl.exe -x http://127.0.0.1:10808 https://ipinfo.io/country
```

باید `DE` چاپ شود. اگر چیز دیگری دیدید، سرور را عوض کنید.

### Xray-core بدون کلاینت گرافیکی (لینوکس / مک)

اگر Xray را مستقیم اجرا می‌کنید، بخش `inbounds` کانفیگ باید این‌طور باشد (بخش `outbounds` همان کانفیگ سرور شماست):

```json
{
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": { "udp": true }
    }
  ]
}
```

```bash
xray run -c config.json
```

`listen` حتماً `127.0.0.1` باشد، نه `0.0.0.0`.

---

## ۲. نصب

اول مخزن را بگیرید:

```bash
git clone https://github.com/hfeizbakhshian/claude-no-leak.git
cd claude-no-leak
```

اسکریپت نصب، اگر Claude نصب نباشد، نسخه‌ی رسمی را **از طریق همان پروکسی** دانلود و نصب می‌کند؛ پس قبل از اجرا v2ray باید روشن باشد. اجرای دوباره‌ی اسکریپت بی‌خطر است: لاگین و تاریخچه‌ی Claude را پاک نمی‌کند.

اسکریپت یک فایل `~/.claude/CLAUDE.md` (دستورالعمل‌های Claude برای همان سیستم‌عامل) هم نصب می‌کند و نسخه‌ی قبلی را با پسوند `.backup` نگه می‌دارد.

### لینوکس

پیش‌نیازها: `systemd`، `sudo`، `python3`، `curl`.

```bash
bash linux-native/claude_native_setup.sh
```

یک بار رمز `sudo` را می‌پرسد تا `/usr/local/bin/claude-jail` و یک قانون sudoers فقط برای همان فایل را نصب کند. بعد از آن، اجرای Claude دیگر رمز نمی‌خواهد.

### مک

پیش‌نیازها: `python3` و `curl`. اگر `python3` نصب نیست:

```bash
xcode-select --install
```

بعد:

```bash
bash mac-native/claude_native_setup.sh
```

دسترسی ادمین لازم نیست.

> **توجه:** قابلیت `/sandbox` خودِ Claude Code هم از `sandbox-exec` استفاده می‌کند و مک معمولاً اجازه‌ی یک sandbox داخل sandbox دیگر را نمی‌دهد، پس آن قابلیت ممکن است داخل این محیط کار نکند.

### لینوکس و مک: PATH

wrapper در `~/.local/bin/claude` نصب می‌شود. اگر این پوشه در PATH نیست، اضافه‌اش کنید (`~/.zshrc` در مک، `~/.bashrc` در لینوکس):

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

و یک ترمینال جدید باز کنید.

### ویندوز

PowerShell را **Run as Administrator** باز کنید (ساختن قانون فایروال دسترسی ادمین می‌خواهد):

```powershell
cd claude-no-leak
powershell -ExecutionPolicy Bypass -File .\windows-native\claude_native_setup.ps1
```

اسکریپت پوشه‌ی `%USERPROFILE%\.claude-proxy-wrapper` را به ابتدای PATH اضافه می‌کند. **یک ترمینال جدید باز کنید** تا اعمال شود.

> در ویندوز، پروکسی از نوع HTTP استفاده می‌شود. پورت `10808` در v2rayN هر دو نوع را جواب می‌دهد؛ اگر کلاینت شما HTTP را روی پورت دیگری (مثلاً `10809`) می‌دهد، قبل از اجرا `$env:CLAUDE_PROXY_PORT = 10809` را بزنید.

### داکر (قدیمی)

پیش‌نیازها: داکر، و پروکسی‌ای که از داخل کانتینر در دسترس باشد. برای همین در این حالت باید **«Allow connections from LAN»** در v2rayN روشن باشد (یا در Xray: `"listen": "0.0.0.0"`)، و پورت `10808` هم SOCKS و هم HTTP را جواب بدهد.

```bash
bash docker/claude_startup.sh
```

---

## ۳. اجرا

در هر سه سیستم‌عامل فقط کافی است بزنید:

```bash
claude
```

wrapper قبل از اجرای Claude این‌ها را چک می‌کند و اگر هر کدام رد شود، Claude را اجرا نمی‌کند:

1. پروکسی روی `127.0.0.1:10808` روشن است.
2. IP خروجی پروکسی در کشور مورد انتظار است.
3. `api.anthropic.com` از طریق پروکسی در دسترس است.
4. کلید قطع واقعاً فعال است (در لینوکس و مک با یک تست واقعی شبکه از داخل محیط بسته).

---

## ۴. تنظیمات

همه با متغیر محیطی، قبل از اجرای `claude` (یا اسکریپت نصب):

| متغیر | پیش‌فرض | کاربرد |
|---|---|---|
| `CLAUDE_EXPECTED_COUNTRY` | `DE` | کد دوحرفی کشوری که IP خروجی باید در آن باشد |
| `CLAUDE_TIMEZONE` | `Europe/Berlin` | منطقه‌ی زمانی Claude؛ با کشور خروجی هماهنگش کنید |
| `CLAUDE_COUNTRY_RECHECK_SECONDS` | `120` | فاصله‌ی بررسی دوباره‌ی کشور حین کار |
| `CLAUDE_SOCKS_PORT` | `10808` | پورت SOCKS5 (لینوکس و مک) |
| `CLAUDE_PROXY_PORT` | `10808` | پورت پروکسی HTTP (ویندوز) |
| `CLAUDE_RELEASE_CHANNEL` | `latest` | کانال نسخه‌ی Claude موقع نصب (`latest` یا `stable`؛ لینوکس و مک) |
| `CLAUDE_REAL_BINARY` | — | مسیر دستی فایل اجرایی Claude، اگر پیدا نشد (لینوکس و مک) |

مثال، برای سرور هلند:

```bash
export CLAUDE_EXPECTED_COUNTRY=NL
export CLAUDE_TIMEZONE=Europe/Amsterdam
claude
```

```powershell
$env:CLAUDE_EXPECTED_COUNTRY = 'NL'
$env:CLAUDE_TIMEZONE = 'Europe/Amsterdam'
claude
```

پروکسی فقط روی `127.0.0.1` پذیرفته می‌شود؛ آدرس دیگری بدهید، wrapper اجرا نمی‌شود.

---

## ۵. رفع اشکال

| پیغام | علت و راه‌حل |
|---|---|
| `proxy is not listening on 127.0.0.1:10808` | v2ray خاموش است یا روی پورت دیگری است. روشنش کنید، یا پورت را با متغیرهای بالا عوض کنید. |
| `the proxy exit IP is in 'XX', expected 'DE'` | سرور انتخاب‌شده آلمان نیست. سرور را عوض کنید، یا `CLAUDE_EXPECTED_COUNTRY` را تنظیم کنید. |
| `... is in 'unknown'` | پروکسی وصل نیست یا سرور جواب نمی‌دهد. تست `curl` بخش ۱ را بزنید. |
| خطای HTTP 403 موقع نصب | IP این سرور توسط `downloads.claude.ai` بلاک شده. سرور دیگری انتخاب کنید و اسکریپت را دوباره اجرا کنید. |
| `Anthropic is unreachable through the ... proxy` | پروکسی وصل است ولی به Anthropic نمی‌رسد. سرور را عوض کنید. |
| `the proxy exit IP moved to 'XX'. Cutting the tunnel.` | وسط کار IP خروجی عوض شد و تونل عمداً قطع شد. سرور را درست کنید و `claude` را دوباره اجرا کنید. |
| `the network jail is not being enforced` / `could not be set up` | کلید قطع فعال نشد و Claude برای جلوگیری از نشت اجرا نشد. اسکریپت نصب همان سیستم‌عامل را دوباره اجرا کنید. |
| ویندوز: `kill-switch firewall rule is missing` | اسکریپت نصب را دوباره با PowerShell ادمین اجرا کنید (مثلاً بعد از آپدیت Claude که مسیر فایلش عوض شده). |
| `claude: command not found` | PATH تنظیم نشده؛ بخش PATH یا باز کردن ترمینال جدید. |

بعد از آپدیت Claude یا هر مشکلی، اجرای دوباره‌ی اسکریپت نصب بی‌خطر است.
