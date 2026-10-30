# سند شکست پروژه و تعاریف زیرماژول‌ها (Partitioning Document)
## تفکیک شتاب‌دهنده سخت‌افزاری FCNN به زیرماژول‌ها و هدرهای دقیق رابط‌ها

---

### ۱. معماری کلی و راهبرد تفکیک (Architectural Breakdown)
بر اساس الزامات صورت‌پروژه، سیستم به دو بخش اصلی **مسیر داده (Datapath)** و **واحد کنترل (Controller)** تقسیم شده است. در کل طراحی، منابع محاسباتی به **یک ضرب‌کننده FP16** و **یک جمع‌کننده FP16** محدود شده‌اند. زیرماژول‌های تفکیک‌شده عبارتند از:

1. **`sram_weights_model`**: مدل رفتاری حافظه SRAM وزن‌ها و بایاس‌ها (تأخیر ۷ سیکل، خروجی ۱۱۲ بیت معادل ۷ مقدار FP16).
2. **`sram_inputs_model`**: حافظه ورودی پیکسل‌های تصویر تست (خروجی ۷ مقدار FP16 با هماهنگی کامل).
3. **`fp16_multiplier`**: هسته ضرب‌کننده ممیز شناور ۱۶ بیتی مطابق استاندارد IEEE 754.
4. **`ping_pong_buffer`**: بافر دوگانه پینگ‌پونگی برای تطبیق نرخ تولید ضرب‌کننده و نرخ مصرف جمع‌کننده (شامل ۲ بلوک ۷ تایی).
5. **`fp16_adder`**: هسته جمع‌کننده ممیز شناور ۱۶ بیتی همراه با رجیستر انباشت‌گر (Accumulator) و پشتیبانی از اضافه کردن بایاس.
6. **`relu_unit`**: واحد اعمال تابع غیرخطی `ReLU(x) = (x > 0) ? x : 0` بر روی مقادیر لایه اول.
7. **`layer2_regfile`**: رجیستر فایل ده خانه‌ای ۱۶ بیتی برای نگه‌داری مقادیر لایه اول (ورودی لایه دوم) و سپس مقادیر نهایی لایه دوم
8. **`fcnn_controller`**: ماشین وضعیت اصلی (FSM) برای هماهنگی مراحل آدرس‌دهی، شروع ضرب، سوییچ پینگ‌پونگ، انباشت و صدور سیگنال اتمام.
9. **`fcnn_top`**: ماژول سطح بالا (Top-level) که تمامی بخش‌های فوق را یکپارچه می‌سازد.

---

### ۲. نمودار ارتباطی و مسیر داده دقیق با نمادهای سخت‌افزاری و مالتی‌پپلکسرها (Detailed Datapath Schematic)



#### تشریح ساختار مسیر داده و نقش مالتی‌پپلکسرها (Datapath & Multiplexer Breakdown):

1. **مالتی‌پپلکسر انتخاب وزن (`MUX_W 7:1`):**
   - **ورودی‌ها:** ۷ رجیستر ۱۶ بیتی نگه‌دارنده سطر وزن خوانده‌شده از SRAM (`w0` تا `w6`).
   - **سیگنال انتخاب:** `mult_elem_sel[2:0]` از طرف کنترلر (شمارش ۰ تا ۶).
   - **خروجی:** وزن جاری ۱۶ بیتی FP16 متصل به ورودی A ضرب‌کننده.

2. **مالتی‌پپلکسر انتخاب پیکسل ورودی (`MUX_IN_7 7:1`):**
   - **ورودی‌ها:** ۷ رجیستر ۱۶ بیتی نگه‌دارنده پیکسل‌های تصویر ورودی (`x0` تا `x6`).
   - **سیگنال انتخاب:** `mult_elem_sel[2:0]`.
   - **خروجی:** پیکسل جاری لایه اول.

3. **مالتی‌پپلکسر انتخاب ورودی لایه ضرب‌کننده (`MUX_LAYER_IN 2:1`):**
   - **ورودی ۰:** خروجی پیکسل لایه اول از `MUX_IN_7`.
   - **ورودی ۱:** ویژگی لایه مخفی از `layer2_regfile` (`l2_rd_data[15:0]`).
   - **سیگنال انتخاب:** `layer_sel` (مقدار ۰ برای لایه اول، ۱ برای لایه دوم).
   - **خروجی:** متصل به ورودی B ضرب‌کننده FP16.

4. **دی‌مالتی‌پپلکسر نوشتن بافر پینگ‌پونگ (`Write DeMux`):**
   - هدایت خروجی ضرب‌کننده (`prod[15:0]`) به `Bank 0` یا `Bank 1` بر اساس بیت وضعیت `bank_select`.

5. **مالتی‌پپلکسر خواندن بافر پینگ‌پونگ (`MUX_PP_READ 2:1`):**
   - انتخاب بانک مخالف برای خواندن توسط جمع‌کننده بر اساس `bank_select`.

6. **مالتی‌پپلکسر ورودی دوم جمع‌کننده (`MUX_ADD_OP2 2:1`):**
   - **ورودی ۰:** داده خوانده‌شده از بافر پینگ‌پونگ (`pp_val[15:0]`).
   - **ورودی ۱:** مقدار بایاس نورون جاری `C_j` (`bias_val[15:0]`).
   - **سیگنال انتخاب:** `add_bias_sel` (در طول ضرب‌ها مقدار ۰، در گام آخر هر نورون مقدار ۱).

7. **حلقه انباشت‌گر و هسته جمع‌کننده (`fp16_adder` + `ACC_REG`):**
   - ورودی A همواره از خروجی رجیستر انباشت‌گر ۱۶ بیتی تامین می‌شود.
   - ورودی B از خروجی `MUX_ADD_OP2` تامین می‌شود.
   - خروجی جمع مستقیماً در لبه کلاک در `accumulator` بازنویسی می‌گردد (`accum_clr` برای شروع نورون جدید صفر می‌کند).

8. **مالتی‌پپلکسر بای‌پس ReLU برای لایه دوم (`MUX_L2_WR 2:1`):**
   - **ورودی ۰ (لایه اول):** خروجی عبوریافته از واحد فعال‌سازی `relu_unit` (`max(0, H_j)`).
   - **ورودی ۱ (لایه دوم):** مقدار خام انباشت‌گر بدون عبور از ReLU (`raw_accum[15:0]`).
   - **سیگنال انتخاب:** `layer_sel` (در لایه اول مقدار ReLU ذخیره می‌شود و در لایه دوم مقدار خام لاجیت).
   - **خروجی:** متصل به پورت ورودی نوشتن `layer2_regfile` (`wr_data[15:0]`).

9. **مدار مقایسه‌گر ماکسیمم (`ArgMax Tree`):**
   - مقایسه موازی ۱۰ مقدار خروجی لایه دوم برای استخراج شاخص بیشترین لاجیت (`pred_digit[3:0]`).

---

### ۳. تعریف دقیق هدر ماژول‌ها (Module Headers & Port Specifications)

#### ۳.۱. ماژول حافظه وزن‌ها (`sram_weights_model`)
این ماژول رفتار SRAM را شبیه‌سازی می‌کند؛ با دریافت آدرس، پس از ۷ سیکل کلاک داده‌ی ۱۱۲ بیتی شامل ۷ عدد FP16 را برمی‌گرداند.

```verilog
module sram_weights_model (
    input  wire        clk,
    input  wire        rst,
    input  wire        read_en,
    input  wire [9:0]  addr,        // آدرس سطرها (هر سطر ۱۱۲ بیت)
    output reg  [111:0] data_out,    // ۷ عدد FP16 به صورت متوالی {w6, w5, w4, w3, w2, w1, w0}
    output reg         data_valid   // پس از ۷ سیکل فعال می‌شود
);
```

#### ۳.۲. ماژول حافظه ورودی‌ها (`sram_inputs_model`)
این ماژول مقادیر پیکسل‌های ورودی (۷۸۴ عدد FP16) را نگه داشته و به صورت بسته‌های ۷ تایی (۱۱۲ بیتی) عرضه می‌کند.

```verilog
module sram_inputs_model (
    input  wire        clk,
    input  wire        rst,
    input  wire        read_en,
    input  wire [6:0]  addr,        // آدرس بسته‌های ۷ تایی (112 بسته = 784 عدد)
    output reg  [111:0] data_out,    // ۷ عدد FP16 ورودی
    output reg         data_valid   // فعال پس از آماده‌سازی
);
```

#### ۳.۳. ضرب‌کننده ممیز شناور ۱۶ بیتی (`fp16_multiplier`)
هسته سخت‌افزاری استاندارد IEEE 754 برای ضرب دو عدد FP16.

```verilog
module fp16_multiplier (
    input  wire        clk,
    input  wire        rst,
    input  wire        valid_in,
    input  wire [15:0] a,           // وزن FP16
    input  wire [15:0] b,           // ورودی FP16
    output reg  [15:0] result,      // حاصل‌ضرب FP16
    output reg         valid_out    // اعتبار خروجی
);
```

#### ۳.۴. بافر پینگ‌پونگی (`ping_pong_buffer`)
شامل دو بانک رجیستر ۷ تایی ۱۶ بیتی، سوییچ نقش‌ها با بیت `select` و پرچم‌های `full` و `empty`.

```verilog
module ping_pong_buffer (
    input  wire        clk,
    input  wire        rst,
    // ورودی نوشتن (از سمت ضرب‌کننده)
    input  wire        wr_en,
    input  wire [15:0] wr_data,
    output wire        wr_full,     // بلوک در حال نوشتن پر شده است
    // خروجی خواندن (به سمت جمع‌کننده)
    input  wire        rd_en,
    output reg  [15:0] rd_data,     // ثبت‌شده؛ یک گام پس از بیت خواندن معتبر می‌شود
    output wire        rd_empty,    // بلوک در حال خواندن خالی شده است
    // سیگنال تعویض نقش بانک‌ها (Swap)
    input  wire        swap_req,
    output reg         bank_select  // 0: Bank0 write / Bank1 read | 1: Bank1 write / Bank0 read
);
```

**نکته پیاده‌سازی:** در RTL نهایی `rd_data` و `bank_select` خروجی رجیستر هستند و مسیر خواندن یک گام عقب‌تر از پالس `rd_en` حرکت می‌کند: مقدار خانه‌ای که در گام نشانه‌گیری شده بود، در سیکل بعدی روی `rd_data` ظاهر می‌شود. این تاخیر ثابت یک‌گام، هنگام چیدمان گام‌های جمع‌کننده محاسبه شده است و خطایی ایجاد نمی‌کند؛ `wr_full` و `rd_empty` ترکیبی‌اند (`wr_ptr == 7` و `rd_ptr == 7`).

#### ۳.۵. جمع‌کننده و انباشت‌گر ممیز شناور ۱۶ بیتی (`fp16_adder`)
واحد محاسباتی برای جمع دو مقدار FP16، دارای رجیستر داخلی Accumulator و قابلیت دریافت بایاس.

```verilog
module fp16_adder (
    input  wire        clk,
    input  wire        rst,
    input  wire        start_add,   // فرمان شروع یک عمل جمع
    input  wire        clr_accum,   // پاک کردن رجیستر انباشت‌گر (صفر کردن)
    input  wire        add_bias,    // انتخاب جمع بایاس به جای مقدار بافر
    input  wire [15:0] operand_b,   // داده خوانده شده از بافر یا مقدار بایاس
    output reg  [15:0] accum_out,   // مقدار جاری انباشت‌گر
    output reg         add_done     // اتمام عمل جمع جاری
);
```

#### ۳.۶. واحد فعال‌سازی رلو (`relu_unit`)
محاسبه تابع فعال‌سازی برای مقادیر ممیز شناور لایه اول.

```verilog
module relu_unit (
    input  wire [15:0] data_in,     // مقدار ممیز شناور FP16 ورودی
    output wire [15:0] data_out     // اگر منفی باشد 16'h0000 و در غیر این صورت data_in
);
```

#### ۳.۷. رجیستر فایل لایه دوم (`layer2_regfile`)
۱۸ رجیستر ۱۶ بیتی با قابلیت دسترسی موازی برای خروجی (خانه‌های ۸..۱۷) و دسترسی متوالی برای ورودی ضرب (خانه‌های ۰..۷).

```verilog
module layer2_regfile (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [4:0]  wr_addr,     // آدرس نوشتن (0..7: لایه اول | 8..17: لایه دوم)
    input  wire [15:0] wr_data,     // داده برای نوشتن
    input  wire [4:0]  rd_addr,     // آدرس خواندن برای ضرب‌کننده (0 تا 7)
    output wire [15:0] rd_data,     // داده خوانده‌شده (خواندن ترکیبی)
    output wire [159:0] all_outputs // ۱۰ لاجیت موازی; رقم d روی [159-16d -: 16]
);
```


#### ۳.۸. مسیر داده یکپارچه (`fcnn_datapath`)
این ماژول تمام زیرماژول‌های محاسباتی و حافظه‌ای را در یک واحد ساخت‌یافته مجتمع می‌کند؛ سیگنال‌های کنترلی را از `fcnn_controller` دریافت و وضعیت‌ها را به آن گزارش می‌دهد.
**نکته:** انتخاب داده نوشتن رجیستر فایل درون همین ماژول بین خروجی ReLU و خروجی خام جمع‌کننده (`accum_q`) با `layer_sel` انجام می‌شود و آدرس نوشتن لایه دوم با +۸ جابجا می‌شود (`rf[8+d]`)؛ چون بازه نوشتن با بازه خواندن عملوندها هم‌پوشانی ندارد، نیازی به آرایه موقت خروجی یا انتقال مرحله‌ای نیست (مستند در `03_spec.md` §2.6). همچنین آرایه ۱۸ بایاسی `bias_rom` از `bias.mem` بارگذاری می‌شود.

```verilog
module fcnn_datapath (
    input  wire         clk,
    input  wire         rst,
    // سیگنال‌های کنترلی حافظه‌ها
    input  wire [9:0]   sram_w_addr,
    input  wire         sram_w_read_en,
    input  wire [6:0]   sram_in_addr,
    input  wire         sram_in_read_en,
    output wire         sram_w_valid,
    output wire         sram_in_valid,
    // سیگنال‌های کنترلی ضرب‌کننده و بافر پینگ‌پونگ
    input  wire         mult_en,
    input  wire [2:0]   mult_elem_sel,
    output wire         mult_valid,
    input  wire         buf_wr_en,
    input  wire         buf_rd_en,
    input  wire         buf_swap,
    output wire         buf_full,
    output wire         buf_empty,
    // سیگنال‌های کنترلی جمع‌کننده و انباشت‌گر
    input  wire         add_start,
    input  wire         add_bias_sel,
    input  wire         accum_clr,
    output wire         add_done,
    // انتخاب لایه (ReLU بایپس) و آدرس آرایه بایاس
    input  wire         layer_sel,     // 0: لایه اول (ReLU فعال) | 1: لایه دوم (خام)
    input  wire [4:0]   bias_addr,     // شماره نورون جاری (0..7 لایه1، 8..17 لایه2)
    // سیگنال‌های رجیستر فایل لایه دوم
    input  wire         l2_wr_en,
    input  wire [3:0]   l2_wr_addr,
    input  wire [3:0]   l2_rd_addr,
    // خروجی‌های داده نهایی
    output wire [159:0] logits_out,
    output wire [3:0]   pred_digit
);
```

#### ۳.۹. واحد کنترل و ماشین حالت (`fcnn_controller`)
هماهنگ‌کننده کلیه مراحل و تولید سیگنال‌های کنترلی.

```verilog
module fcnn_controller (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    // ورودی‌های وضعیت از مسیر داده
    input  wire        sram_w_valid,
    input  wire        sram_in_valid,
    input  wire        mult_valid,
    input  wire        buf_full,
    input  wire        buf_empty,
    input  wire        add_done,
    // خروجی‌های کنترل حافظه
    output reg  [9:0]  sram_w_addr,
    output reg         sram_w_read_en,
    output reg  [6:0]  sram_in_addr,
    output reg         sram_in_read_en,
    // خروجی‌های کنترل ضرب و بافر
    output reg         mult_en,
    output reg  [2:0]  mult_elem_sel,
    output reg         buf_wr_en,
    output reg         buf_rd_en,
    output reg         buf_swap,
    // خروجی‌های کنترل جمع‌کننده و رجیستر فایل
    output reg         add_start,
    output reg         add_bias_sel,
    output reg         accum_clr,
    output reg         layer_sel,    // 0: لایه اول (ReLU) | 1: لایه دوم (خام)
    output reg  [4:0]  bias_addr,    // اندیس آرایه بایاس (0..7 L1، 8..17 L2)
    output reg         l2_wr_en,
    output reg  [3:0]  l2_wr_addr,
    output reg  [3:0]  l2_rd_addr,
    // سیگنال‌های نهایی
    output reg         busy,
    output reg         done
);
```

#### ۳.۱۰. ماژول سطح بالا (`fcnn_top` / `fcnn_accelerator_top`)
نمونه‌سازی و اتصال `fcnn_controller` و `fcnn_datapath`.

```verilog
module fcnn_top (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    output wire         busy,
    output wire         done,
    output wire [159:0] logits_out,    // ۱۰ خروجی لایه دوم به صورت موازی (هر کدام ۱۶ بیت)
    output wire [3:0]   pred_digit     // رقم پیش‌بینی‌شده (ArgMax)
);
```
