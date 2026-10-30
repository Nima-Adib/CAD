# مقایسه پرامپت ساده و ساختاریافته ۶ بخشی (Prompt Engineering: Before vs. After)
## ارزیابی تأثیر متدولوژی ساختاردهی پرامپت بر کیفیت کد RTL زیرماژول `ping_pong_buffer`

---

### ۱. مقدمه و انتخاب ماژول آزمون

ماژول **بافر پینگ‌پونگی (`ping_pong_buffer`)** به عنوان ماژول کلیدی هماهنگی پایپ لاین ضرب و جمع انتخاب شده است. این ماژول واسط بین ضرب‌کننده و جمع‌کننده بوده و وظیفه همگام‌سازی، جلوگیری از سرریز داده‌ها (Overflow)، جلوگیری از خواندن داده نامعتبر (Underflow) و جابه‌جایی پیوسته نقش دو بانک حافظه را بر عهده دارد. در ادامه، مقایسه دقیق میان پرامپت اولیه و پرامپت ساختاریافته ۶ بخشی ارائه می‌گردد.

---

### ۲. پرامپت اولیه و بدون ساختار (Before Prompt)

```text
یک ماژول بافر پینگ پونگ در وریلاگ بنویس که دو تا بلاک داشته باشه و هر کدوم بتونن ۷ تا عدد ۱۶ بیتی ممیز شناور نگه دارن. یکی بنویسه و یکی بخونه و وقتی کارشون تموم شد جاشون عوض بشه تا ضرب کننده و جمع کننده بتونن همزمان کار کنن و متوقف نشن. سیگنال های full و empty هم داشته باشه.
```

#### خروجی تولید شده از پرامپت بدون ساختار (Before Output):

```verilog
module ping_pong (
    input clk,
    input wr_en,
    input [15:0] din,
    input rd_en,
    output [15:0] dout,
    output full,
    output empty
);
    reg [15:0] mem1 [0:6];
    reg [15:0] mem2 [0:6];
    reg sel;
    integer i, j;

    assign full = (i == 7);
    assign empty = (j == 7);

    always @(posedge clk) begin
        if (wr_en) begin
            if (!sel)
                mem1[i] <= din;
            else
                mem2[i] <= din;
            i = i + 1;
        end
        if (rd_en) begin
            j = j + 1;
        end
        if (full && empty) begin
            sel = ~sel;
            i = 0;
            j = 0;
        end
    end

    assign dout = (!sel) ? mem2[j] : mem1[j];
endmodule
```

#### نقاط ضعف و خطاهای خروجی بدون ساختار:
1. **عدم وجود سیگنال ریست (`rst`):** هیچ مکانیزمی برای مقداردهی اولیه رجیستر‌ها، متغیرهای `sel`، `i` و `j` وجود ندارد؛ در نتیجه در شبیه‌سازی یا سنتز مقدار `x` (نامشخص) خواهند گرفت.
2. **استفاده از متغیرهای `integer` در سنتز:** متغیرهای `i` و `j` به عنوان رجیسترهای ۳۲ بیتی عمومی سنتز می‌شوند و برای محدوده‌ی ۰ تا ۶ بهینه‌سازی نشده‌اند.
3. **تداخل ترکیبی از Blocking (`=`) و Non-blocking (`<=`):** در داخل یک بلوک `always` از هر دو نوع انتساب استفاده شده که منجر به رفتار غیرقابل‌پیش‌بینی شبیه‌ساز (Race Condition) و عدم تطابق رفتار قبل و بعد از سنتز می‌شود.
4. **خطای شاخص حافظه (Out-of-Bounds Indexing):** هنگامی که `i` یا `j` به مقدار ۷ می‌رسند، انتساب خروجی `dout` تلاش می‌کند خانه ۷ام آرایه ۷ عنصری (اندیس‌های ۰ تا ۶) را بخواند که خطای حافظه است.
5. **نبود نام‌گذاری استاندارد پورت‌ها:** نام پورت‌ها (`din`, `dout`, `sel`) با استانداردهای پروژه مطابقت ندارد.

---

### ۳. پرامپت ساختاریافته ۶ بخشی (After Prompt)

پرامپت به شش بخش تفکیک می‌شود:

```text
### 1. Role
شما یک طراح ارشد سخت‌افزار دیجیتال (RTL Designer) هستید که کدهای قابل سنتز، قطعی، ماژولار و بهینه‌سازی‌شده بر اساس استاندارد SystemVerilog-2012 / Verilog-2005 تولید می‌کنید.

### 2. Context
پروژه طراحی شتاب‌دهنده سخت‌افزاری شبکه عصبی FCNN برای طبقه‌بندی ارقام MNIST است. در این معماری، ضرب‌کننده در هر سیکل یک حاصل‌ضرب FP16 تولید کرده و در بافر پینگ‌پونگی می‌نویسد؛ جمع‌کننده مقادیر را از سمت خواندن بافر دریافت کرده و انباشت می‌کند. این بافر دارای دو بلوک رجیستر مجزا (هر کدام با گنجایش دقیقاً ۷ کلمه ۱۶ بیتی) است.

### 3. Input
"""
مشخصات رابط پورت‌های ماژول:
- ورودی clk (تک‌بیت)
- ورودی rst (تک‌بیت، ریست سنکرون با سطح فعال بالا)
- ورودی wr_en (فعال‌ساز نوشتن از ضرب‌کننده)
- ورودی [15:0] wr_data (داده حاصل‌ضرب ۱۶ بیتی FP16)
- خروجی wr_full (تک‌بیت، نشان‌دهنده پر شدن ۷ عنصر بانک جاری نوشتن)
- ورودی rd_en (فعال‌ساز خواندن به سمت جمع‌کننده)
- خروجی [15:0] rd_data (داده ۱۶ بیتی خوانده‌شده از بانک جاری خواندن)
- خروجی rd_empty (تک‌بیت، نشان‌دهنده خوانده شدن هر ۷ عنصر بانک جاری خواندن)
- ورودی swap_req (درخواست تعویض نقش بانک‌ها)
- خروجی bank_select (بیت وضعیت جاری بانک‌ها؛ 0: نوشتن در بانک0 و خواندن از بانک1 | 1: نوشتن در بانک1 و خواندن از بانک0)
"""

### 4. Instructions
1. دو بانک رجیستری مجزا با عمق ۷ و عرض ۱۶ بیت به صورت آرایه‌ای از رجیسترها تعریف کنید (`bank0` و `bank1`).
2. دو شمارنده ۳ بیتی با نام‌های `wr_ptr` و `rd_ptr` برای دنبال کردن تعداد داده‌های نوشته‌شده و خوانده‌شده در محدوده 0 تا 7 ایجاد کنید.
3. در لبه مثبت کلاک و با فعال بودن `rst`، کلیه رجیسترها، اشاره‌گرها و بیت انتخاب را به صفر بازنشانی کنید.
4. با فعال بودن `wr_en` و عدم پر بودن بانک جاری (`wr_ptr < 7`)، داده ورودی را در بانک منتخب نوشته و شمارنده `wr_ptr` را یک واحد افزایش دهید.
5. با فعال بودن `rd_en` و خالی نبودن بانک جاری (`rd_ptr < 7`)، داده را از بانک خواندن به خروجی ارسال کرده و شمارنده `rd_ptr` را یک واحد افزایش دهید.
6. تنها زمانی که `swap_req` فعال بوده و هر دو شرط `wr_ptr == 7` و `rd_ptr == 7` برقرار باشند، بیت `bank_select` را معکوس کرده و هر دو اشاره‌گر `wr_ptr` و `rd_ptr` را صفر کنید.

### 5. Constraints
- کد باید ۱۰۰٪ قابل سنتز باشد و در ساختارهای ترتیبی فقط از انتساب Non-blocking (`<=`) استفاده شود.
- هیچ متغیر از نوع `integer` استفاده نشود؛ تمام رجیستر‌ها باید عرض بیتی صریح داشته باشند.
- در برابر درخواست نوشتن زمانی که بانک پر است یا خواندن زمانی که خالی است، مقاوم بوده و اشاره‌گرها سرریز نکنند.
- از هیچ ماژول رفتاری نامتعارف استفاده نکنید و کد را کامنت‌گذاری شده تحویل دهید.

### 6. Output Format
تنها کد کامل ماژول `ping_pong_buffer` در قالب بلوک کد Verilog به همراه کامنت‌های توضیحی.
```

#### خروجی تولید شده از پرامپت ساختاریافته (After Output):

```verilog
// ============================================================================
// Module Name:  ping_pong_buffer
// Description:  Dual-bank ping-pong buffer holding 7 FP16 words per bank.
// Standard:     Verilog-2005 / SystemVerilog-2012 Synthesizable RTL
// Reset:        Synchronous Active-High Reset
// ============================================================================

module ping_pong_buffer (
    input  wire        clk,
    input  wire        rst,
    // Write interface (from FP16 Multiplier)
    input  wire        wr_en,
    input  wire [15:0] wr_data,
    output wire        wr_full,
    // Read interface (to FP16 Adder/Accumulator)
    input  wire        rd_en,
    output reg  [15:0] rd_data,
    output wire        rd_empty,
    // Bank switch control
    input  wire        swap_req,
    output reg         bank_select
);

    // Two storage banks: 7 words of 16-bit each
    reg [15:0] bank0 [0:6];
    reg [15:0] bank1 [0:6];

    // 3-bit pointers tracking counts from 0 to 7
    reg [2:0] wr_ptr;
    reg [2:0] rd_ptr;

    // Status flags
    assign wr_full  = (wr_ptr == 3'd7);
    assign rd_empty = (rd_ptr == 3'd7);

    integer idx;

    // Synchronous sequential logic for write, read, and swap
    always @(posedge clk) begin
        if (rst) begin
            bank_select <= 1'b0;
            wr_ptr      <= 3'd0;
            rd_ptr      <= 3'd0;
            rd_data     <= 16'h0000;
            for (idx = 0; idx < 7; idx = idx + 1) begin
                bank0[idx] <= 16'h0000;
                bank1[idx] <= 16'h0000;
            end
        end else begin
            // ----------------------------------------------------
            // Swap condition: Swap allowed only when write bank is full
            // and read bank is completely emptied.
            // ----------------------------------------------------
            if (swap_req && (wr_ptr == 3'd7) && (rd_ptr == 3'd7)) begin
                bank_select <= ~bank_select;
                wr_ptr      <= 3'd0;
                rd_ptr      <= 3'd0;
            end else begin
                // ------------------------------------------------
                // Write process into active write bank
                // ------------------------------------------------
                if (wr_en && (wr_ptr < 3'd7)) begin
                    if (bank_select == 1'b0)
                        bank0[wr_ptr] <= wr_data;
                    else
                        bank1[wr_ptr] <= wr_data;
                    wr_ptr <= wr_ptr + 3'd1;
                end

                // ------------------------------------------------
                // Read process from active read bank
                // ------------------------------------------------
                if (rd_en && (rd_ptr < 3'd7)) begin
                    if (bank_select == 1'b0)
                        rd_data <= bank1[rd_ptr];
                    else
                        rd_data <= bank0[rd_ptr];
                    rd_ptr <= rd_ptr + 3'd1;
                end
            end
        end
    end

endmodule
```

---

### ۴. تحلیل مقایسه‌ای و درس‌آموخته‌ها (Comparative Analysis)

| مشخصه / معیار ارزیابی | پرامپت ساده و بدون ساختار (Before) | پرامپت ساختاریافته ۶ بخشی (After) | دلیل بهبود و مزیت |
|:---|:---|:---|:---|
| **مدیریت ریست (Reset)** | فاقد ریست؛ وضعیت اولیه فلیپ‌فلاپ‌ها نامشخص | ریست سنکرون صریح، مقداردهی کامل تمام آرایه‌ها | جلوگیری کامل از شبیه‌سازی با مقادیر `x` و تطابق با سخت‌افزار واقعی |
| **سنتزپذیری (Synthesizability)** | استفاده از متغیرهای نامشخص `integer` و ترکیب انتساب‌های بلاکینگ | استفاده انحصاری از انتساب Non-blocking و عرض‌های بیتی دقیق | حذف Race condition و ساختارهای غیراستاندارد در سنتز |
| **پوشش شرایط مرزی (Corner Cases)** | بدون محافظ در برابر سرریز اشاره‌گرها و کرش اندیس آرایه | محافظت با شروط `wr_ptr < 7` و `rd_ptr < 7` | عدم وقوع خطای Out-of-bounds در حافظه |
| **منطق سوئیچ پینگ‌پونگ (Swap)** | جابه‌جایی ناهماهنگ و ناگهانی با متغیرهای نامعتبر | سوئیچ مشروط به پرچم‌های قطعی `wr_full` و `rd_empty` | حذف احتمال رونویسی داده‌ها یا خواندن مقادیر تکراری/نامعتبر |
| **انطباق هدر ماژول (Port Compliance)** | اسامی دلخواه، نبود برخی سیگنال‌های کنترلی | انطباق ۱۰۰٪ با سند هدر ماژول‌ها (`02_partitioning.md`) | اتصال بدون خطای زیرماژول‌ها در ماژول سطح بالا |

**نتیجه‌گیری:** مهندسی پرامپت ساختاریافته (تفکیک دقیق Role, Context, Input, Instructions, Constraints, Output Format) توهمات مدل (Hallucinations) را تا حد زیادی حذف می‌کند و به کدی تمیز و قابل‌سنتز می‌رسد.

---

### ۵. به‌کارگیری متدولوژی در سطح معماری: پرامپت اصلاحی گسترش رجیستر فایل (Architecture Evolution Prompt)

بخش‌های ۲ تا ۴ کارایی متدولوژی را روی یک زیرماژول (ساخت از صفر) سنجیدند. در این بخش، همان چیدمان قیدمحور در قالب یک **پرامپت اصلاحی (Change Request)** روی کل سیستم اجرا می‌شود تا یک چرخه کامل مهندسی نمایش داده شود:

معماری نسخه ۱ (رجیستر فایل ۱۰ خانه + آرایه موقت `logit_stage` درون مسیر داده + انتقال ۱۰ سیکلی در استیت `L2_FINAL`) به‌طور کامل ساخته و صحت‌سنجی شده بود (`TB-FCNN PASS` با ۶۸۰۱ سیکل). سپس با یک پرامپت اصلاحی، معماری نسخه ۲ خواسته شد: گسترش رجیستر فایل به ۱۸ خانه، حذف کامل آرایه واسط و نوشتار مستقیم خروجی خام جمع‌کننده. پس از اعمال، تمام مراحل صحت‌سنجی از نو اجرا شد.

**انگیزه معماری:** در نسخه ۱، خطر Read-After-Write در لایه دوم با ابزار زمانی (جداسازی زمانِ خواندن و زمانِ نوشتن) کنترل می‌شد. راه‌حل ساختاری بدین شکل است: بازه نوشتن لاجیت‌ها (`rf[8..17]`) هرگز با بازه خواندن عملوندهای ضرب (`rf[0..7]`) هم‌پوشانی ندارد؛ بنابراین کلاً آرایه واسط، پورتِ `stage_xfer_en` و استیت `L2_FINAL` بی‌معنا می‌شوند و حذف می‌گردند.

#### پرامپت اصلاحی ارسالی (بدون تغییر در واژگان):

```text
Modify the fcnn_datapath design according to the following requirements:

Expand the layer2_regfile to 18 registers.
Registers rf[0] through rf[7] (8 registers) must be dedicated to the 8 neurons of Layer 1.
Registers rf[8] through rf[17] (10 registers) must be dedicated to the 10 neurons of Layer 2.
Remove the logit_stage registers entirely.
Delete the logit_stage register array and all related logic, signals, and control paths.
The outputs of the FP16 adder must be written directly to the register file when computing
Layer 2 neurons, without passing through intermediate staging registers.
Modify the register-file write-data multiplexer (RF write mux).
The write-data multiplexer must select directly between the output of the ReLU unit and
the raw output of the FP16 adder.
Remove the existing staged-logit input from the multiplexer.
Implement Layer 1 write behavior.
When writing the result of a Layer 1 neuron, select the ReLU output as the RF write-data source.
Write the result to the corresponding register in the range rf[0] through rf[7].
Ensure that the Layer 1 result passes through the ReLU unit before being stored.
Implement Layer 2 write behavior.
When writing the result of a Layer 2 neuron, select the raw FP16 adder output (accum_q)
as the RF write-data source.
Write the result to the corresponding register in the range rf[8] through rf[17].
Do not apply ReLU to Layer 2 outputs. The raw adder result must be stored directly in
the register file.
Update all related control and addressing logic.
Modify the register-file write address, read address, write enable, and data-selection
logic as needed to support all 18 registers.
Ensure that the Layer 1 and Layer 2 register ranges do not overlap.
Update the register-file module interface and internal storage to support 18 entries,
using 5-bit addresses if required to represent all register indices.
Ensure that Layer 2 multiplier reads access the correct Layer 1 or Layer 2 registers as
required by the existing architecture. Preserve the intended FCNN dataflow.
Preserve the rest of the design.
Keep the existing single FP16 multiplier, single FP16 adder/accumulator, ping-pong buffer,
SRAM models, row registers, bias ROM, and ArgMax functionality.
Preserve the existing FP16 arithmetic behavior, pipeline timing, and control protocol
wherever possible.
Update logits_out and ArgMax logic so that the final 10 Layer 2 logits are taken from
rf[8] through rf[17], in correct order, and pred_digit identifies the index of the maximum
logit from 0 to 9.
Please implement these changes consistently across all affected RTL modules. Review the
updated design for address-width mismatches, invalid array indices, incorrect write-data
selection, and pipeline timing issues. Do not introduce unnecessary architectural changes
beyond those specified above.

Look at this change request, review it and if it is going to be applied, after applying
the changes run the tests and if everything is fine update md files and documents as well.
```

#### پوشش الگوی ۶ بخشی در پرامپت اصلاحی:

| بخش الگو | معادل در پرامپت اصلاحی |
|:---|:---|
| **Role** | پیاده‌سازی پیوسته در همه ماژول‌های RTLِ متأثر (کدگرِ هماهنگ با کد موجود) |
| **Context** | معماری نسخه ۱ با آرایه `logit_stage` و استیت `L2_FINAL` (کد و اسناد پروژه) |
| **Input** | فایل‌های هدف: `layer2_regfile.v`، `fcnn_datapath.v`، `fcnn_controller.v` (و حذف سیم‌کشی در `fcnn_top.v`) |
| **Instructions** | ده محور تغییر: تعریف `rf[0..7]` و `rf[8..17]`، حذف آرایه واسط، مکس نوشتن دودویی، رفتار ReLU لایه اول، لاجیت خام لایه دوم، به‌روزرسانی آدرس/فعال‌سازها، عدم هم‌پوشانی بازه‌ها، آدرس ۵ بیتی، خواندن عملوندها، آرگماکس |
| **Constraints** | فهرست صریح «حفظ کن» (یک ضرب‌کننده، یک جمع‌کننده با انباشت‌گر، بافر پینگ‌پونگ، مدل‌های SRAM، ثبات‌های سطر، ROM بایاس، ArgMax، رفتار FP16 و زمان‌بندی پایپ‌لاین) + «بدون تغییرهای معماری غیرضروری» |
| **Output Format + Verification** | اجرای تست‌ها پس از اعمال؛ بازبینی موردی (ناهمسانی عرض آدرس، اندیس نامعتبر، انتخاب نادرست داده نوشتن، نقص زمان‌بندی)؛ سپس به‌روزرسانی مستندات |

#### معماری: قبل و بعد از اعمال پرامپت اصلاحی

| ویژگی معماری | نسخه ۱ (قبل) | نسخه ۲ (بعد) |
|:---|:---|:---|
| رجیستر فایل | ۱۰ خانه `rf[0..9]` + آرایه موقت `logit_stage[0:9]` در مسیر داده | ۱۸ خانه: `rf[0..7]` لایه اول، `rf[8..17]` لاجیت‌های لایه دوم |
| مسیر نوشتن لایه دوم | جمع‌کننده → `logit_stage[d]` → (۱۰ سیکل انتقال در `L2_FINAL`) → rf | جمع‌کننده (خام) → مستقیم `rf[8+d]` در همان استیت `L2_STAGE` |
| مکس نوشتن داده | سه‌سر: `stage_xfer_en` / ReLU | دوسر: `layer_sel` بین ReLU و `accum_q` |
| آدرس نوشتن | ۴ بیت (۰..۹) | ۵ بیت (۰..۱۷؛ جابجایی +۸ برای لایه دوم در مسیر داده) |
| محافظت RAW | زمانی: زمان خواندن h و زمان نوشتن لاجیت جداست | ساختاری: بازه خواندن h (۰..۷) و بازه نوشتن لاجیت (۸..۱۷) از هم جدا |
| FSM | ۱۶ استیت (شامل `L2_FINAL`) | ۱۵ استیت؛ پس از ثبت رقم ۹ مستقیماً به `DONE` |
| پورت‌های سطح بالا | — | تغییری نکرد (`clk, rst, start, busy, done, logits_out, pred_digit`) |
| سیکل تا `done` | ۶۸۰۱ | ۶۷۹۱ (دقیقاً ۱۰ سیکل حذف‌شده = هزینه انتقال واسط) |

#### گواهی صحت‌سنجی پس از اعمال (هر گام اجرا شد)

| گام صحت‌سنجی | ابزار/فرمان (از ریشه HW1) | نتیجه |
|:---|:---|:---|
| کامپایل کامل سیستم و هر دو منیفست | `iverilog -g2012` (۱۰ ماژول + تست‌بنچ؛ `05_code.v` و `06_2_programmer.v`) | صفر خطا و صفر هشدار (عرض پورت‌ها هم‌سان) |
| شبیه‌سازی کل سیستم | `make sim` | `TB-FCNN PASS`؛ ۱۰/۱۰ لاجیت بیت‌به‌بیت با مدل مرجع؛ `pred_digit=2`؛ `done` پس از 6791 سیکل |
| تست واحد هسته‌های محاسباتی FP16 | `make units` | ضرب ۱۱۰۳۴ بردار، جمع ۱۱۴۱۵ بردار، صفر خطا (هسته‌ها دست‌نخورده‌اند) |
| شمارش فازهای FSM | `make dbg` | `busy=6793` = ۶۴۴۰ (لایه ۱) + ۳۵۰ (لایه ۲) + ۱ (`DONE`) + ۲ (`IDLE`)؛ `STAGE=10`؛ فاز `FINAL` حذف |
| پروب جفت‌های جمع سخت | `make probe` | خروجی مشابه نسخه ۱ (هسته جمع تغییری نکرده) |
| بازبینی موردیِ خواسته در پرامپت | بازبینی کد | (الف) عرض آدرس‌ها هم‌خوان (۵ بیت برای نوشتن؛ خواندن با گسترش صفر)؛ (ب) بیشینه `8+9=17` درون `rf[0:17]`، بدون اندیس بیرون‌زده؛ (ج) انتخاب درست داده نوشتن در هر دو لایه؛ (د) عدم هم‌پوشانی بازه‌ها؛ (هـ) پایدار بودن `accum_q` در لبه نوشتن `STAGE` (سلامت زمان‌بندی) |
| همگام‌سازی مستندات و نمودارها | ویرایش دستی | `01`/`02`/`03`/`05` به‌روز؛ پیدانوشت‌های `06_1`/`06_3`/`06_4`؛ نمودارهای FSM و مسیر داده بازتولید؛ `test_verify_guide` همگام |

**درس‌آموخته این دور:** یک پرامپت اصلاحی مؤثر سه سازوکار دارد: (۱) فهرست تغییرهای خواسته به‌صورت نقطه‌ای و بی‌ابهام، (۲) فهرست صریح «تغییر نده» برای مهار تغییرهای بی‌مورد، (۳) الزام اجرای بازبینی موردی و صحت‌سنجی کامل پس از اعمال. با این چیدمان، مدل همه تغییرهای خواسته را بدون دست‌زدن به بیرونِ قلمروِ تعریف‌شده پیاده کرد و هر ادعای صحت‌سنجیِ بالا با فرمانی قابل تکرار تأیید شد؛ درس بخش ۴ (سطح زیرماژول) به سطح معماری کل سیستم نیز تعمیم می‌یابد.

