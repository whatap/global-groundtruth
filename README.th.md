# WhaTap Global Groundtruth

> **Languages:** [English (canonical)](README.md) · [Bahasa Indonesia](README.id.md) · ไทย · [한국어](README.ko.md)
>
> **คุณเป็นวิศวกรภาคสนามใช่ไหม?** ไม่จำเป็นต้องอ่านหน้านี้ทั้งหมด
> อ่าน **[คู่มือภาคสนาม](FIELD-GUIDE.th.md)**
> ([English](FIELD-GUIDE.md) · [Bahasa Indonesia](FIELD-GUIDE.id.md) · [한국어](FIELD-GUIDE.ko.md))
> — มีที่มา คำสั่งที่ต้องใช้แบบตรงตัว และสิ่งที่ต้องส่งกลับ

**framework สำหรับ diagnostic collector** แบบหลายโดเมน สำหรับงาน support ของ
WhaTap

*collector* แต่ละตัวเก็บข้อเท็จจริงของสภาพแวดล้อมที่มองไม่เห็นจากระยะไกล
ซึ่งนักพัฒนา agent ของ WhaTap ต้องใช้ วิศวกรภาคสนามจึงรันเพียง **หนึ่งคำสั่ง**
แล้วส่งกลับ **รายงานที่ครบถ้วนหนึ่งฉบับ** วิธีนี้ตัดการถาม-ตอบวินิจฉัยไป-กลับ —
ปัญหา "ยี่สิบคำถาม" — ที่ทำให้เคส support ของโดเมน K8s, server, APM และ DB
ล่าช้าออกไปทั้งหมด

## ที่มา

เคส support ทางไกลมักติดขัดที่ข้อเท็จจริงของสภาพแวดล้อม ไม่ใช่ที่การวิเคราะห์
นักพัฒนาที่ตีความอาการได้อยู่ไกลจากระบบที่แสดงอาการ ส่วนวิศวกรที่อยู่ข้างระบบ
ก็ไม่มีทางรู้ล่วงหน้าว่านักพัฒนาจะต้องใช้ข้อเท็จจริงข้อไหนจากเป็นพัน ๆ ข้อ
เคสจึงดำเนินไปแบบวันละหนึ่งคำถาม — "ใช้ runtime อะไร?", "log อยู่ที่ไหน
จริง ๆ?", "JVM รันด้วย flag อะไร?" — และยิ่งยืดออกไปด้วยโซนเวลาและการส่งต่อ
ข้อความผ่านแชต คำถามสิบข้ออาจกินเวลาตามปฏิทินไปสองสัปดาห์ เพื่องานจริงเพียง
หนึ่งชั่วโมง

collector แทนที่บทสนทนานั้นด้วยผลลัพธ์ชิ้นเดียว: วิศวกรภาคสนามรันสคริปต์
หนึ่งตัวแล้วส่งกลับไฟล์หนึ่งไฟล์ ซึ่งมีคำตอบของคำถามที่นักพัฒนาจะถามอยู่แล้ว —
รวมถึงคำถามข้อถัดไปด้วย ชื่อของมันบอกเป้าหมายไว้ชัดเจน: รายงานทุกฉบับคือ
**ground truth** ของสภาพแวดล้อม — ข้อเท็จจริงจากการสังเกต ไม่มีการตีความ

## ทำไมต้องเป็น framework

รูปแบบการวินิจฉัยใช้ร่วมกันได้ทุกโดเมน แต่ **โค้ด** ของการเก็บข้อมูลใช้ร่วมกัน
ไม่ได้ รีโพซิทอรีนี้จึงประกอบด้วย **contract + format + template + validator**
ที่ใช้ร่วมกัน บวกกับ **การอิมพลีเมนต์รายโดเมน** ที่ทีมของแต่ละโดเมนเป็นเจ้าของ
วิศวกรภาคสนามหนึ่งคน หนึ่งคำสั่ง หนึ่งการ paste — แล้วผู้อ่าน (นักพัฒนา agent)
จะได้ข้อเท็จจริง ground-truth แทนที่จะได้แบบสอบถาม

## Contract ในหนึ่งลมหายใจ

อ่าน [CONTRACT.md](CONTRACT.md) — มีสี่กฎและต่อรองไม่ได้:

1. **ข้อเท็จจริงเท่านั้น** — ไม่มีการวินิจฉัย ไม่มีสาเหตุที่น่าจะเป็น ไม่มี
   คำแนะนำ ไม่มีวิธีแก้
2. **ค้นหาเอง อย่าสันนิษฐาน** — resolve symlink/mount/การตั้งค่า;
   สภาพแวดล้อมใหม่ต้องไม่ต้องแก้โค้ด
3. **หนึ่งคำสั่งภาคสนาม → paste ผลลัพธ์** — วิศวกรรันสิ่งเดียวและคัดลอกทั้งหมด
4. **ทีมโดเมนเป็นเจ้าของ** — เจ้าของ framework ให้โครง; collector แต่ละตัว
   เป็นของนักพัฒนาในโดเมนนั้น

รายงานทุกฉบับใช้รูปแบบเดียวกัน (header → เซกชันข้อเท็จจริงเรียงเลข → footer
คงที่): [docs/output-format.md](docs/output-format.md)

## โครงสร้างรีโพซิทอรี

```
global-groundtruth/
├── README.md                     # this charter (.id/.th/.ko translations alongside)
├── FIELD-GUIDE.md                # field-engineer guide (.id/.th/.ko translations alongside)
├── CONTRACT.md                   # the 4 non-negotiable rules
├── docs/
│   ├── output-format.md          # shared report format spec
│   ├── authoring-guide.md        # how to add a collector
│   ├── collector-engineering.md  # design guidelines: MECE, load tiers, portability, reasoned absence
│   └── coverage-kb/              # environment-specific facts (discover, don't hardcode)
│       └── k8s-huawei-cce.md     # seed entry: Huawei CCE
├── collectors/
│   ├── k8s/                      # SEEDED v0 — cluster-level collector (operator/CR/agents)
│   ├── server/                   # STUB (README only)
│   ├── apm/                      # STUB (README only) — one per language: nodejs/java/python/php/dotnet
│   ├── db/                       # STUB (README only)
│   └── collection-server/        # SEEDED v0 — WhaTap backend (yard/proxy/...) collector
├── templates/
│   └── collector-skeleton/       # copy this to start a collector
└── tools/
    └── validate.sh               # lint: enforces facts-only + header + footer
```

## สถานะของ collector

| โดเมน   | สถานะ          | หมายเหตุ                                              |
|----------|-----------------|----------------------------------------------------|
| `k8s`               | SEEDED v0       | collector ระดับคลัสเตอร์ รันจาก bastion; ดู `collectors/k8s/` |
| `server`            | NOT IMPLEMENTED | สคริปต์ shell บนโฮสต์; ดู `collectors/server/`          |
| `apm`               | NOT IMPLEMENTED | แยกตามภาษา; ดู `collectors/apm/`            |
| `db`                | NOT IMPLEMENTED | SQL + dump การตั้งค่า agent; ดู `collectors/db/`         |
| `collection-server` | SEEDED v0       | สคริปต์บนโฮสต์ backend; ดู `collectors/collection-server/` |

รีโพซิทอรีนี้ประกอบด้วยตัว **framework** (contract, format, template,
validator, เอกสาร), **stub** รายโดเมน และ collector **seeded v0** สองตัว
(`collection-server`, `k8s`) ซึ่งทีม Global เป็นเจ้าของจนกว่าจะส่งมอบ
collector ถูกเขียนขึ้นแล้วส่งต่อให้ทีมโดเมนเป็นเจ้าของ

## การรัน collector (วิศวกรภาคสนาม)

เริ่มจาก **[คู่มือภาคสนาม](FIELD-GUIDE.th.md)** — ระบุคำสั่งที่ต้องใช้ของ
collector แต่ละตัวไว้ตรงตัว รูปแบบเหมือนกันเสมอ: รันสิ่งเดียว แล้วส่งผลลัพธ์
ทั้งหมดกลับมา ไม่มีการขอให้คุณตีความ รายละเอียดรายตัวอยู่ที่
`collectors/<domain>/README.md`

## การเพิ่ม collector (นักพัฒนาของโดเมน)

1. คัดลอก [templates/collector-skeleton/](templates/collector-skeleton/)
   ไปยัง `collectors/<domain>/`
2. เติมข้อเท็จจริง โดยปฏิบัติตาม [CONTRACT.md](CONTRACT.md) และ
   [docs/output-format.md](docs/output-format.md)
3. ตรวจสอบ:
   ```sh
   tools/validate.sh collectors/<domain>/<your-collector>.sh
   ```

คำแนะนำฉบับเต็ม: [docs/authoring-guide.md](docs/authoring-guide.md) สำหรับ
collector ที่แข็งแรง — เซกชันแบบ MECE, tier ที่ปลอดภัยต่อโหลด, ความพกพาได้บน
โฮสต์ที่ไม่รู้จัก และ `n/a` พร้อมเหตุผล — ให้ทำตาม
[docs/collector-engineering.md](docs/collector-engineering.md)

## นโยบายภาษาของเอกสาร

- **สคริปต์เป็นภาษาอังกฤษเท่านั้น** — โค้ด คอมเมนต์ ข้อความ usage/help
  ข้อความแสดงความคืบหน้า และทุกบรรทัดของเอาต์พุตรายงาน รายงานถูก parse โดย
  tool และถูกอ่านโดยนักพัฒนาข้ามภูมิภาค; `tools/validate.sh` และ footer
  sentinel แบบคงที่ยึดกับ string ภาษาอังกฤษแบบตรงตัว ห้ามแปลเอาต์พุตรายงาน
  เด็ดขาด
- **เอกสารสำหรับภาคสนาม** — [FIELD-GUIDE.md](FIELD-GUIDE.md) และ README
  ฉบับนี้ — ดูแลเป็นสี่ภาษา: อังกฤษ บวกอินโดนีเซีย (`.id.md`) ไทย (`.th.md`)
  และเกาหลี (`.ko.md`)
- **ภาษาอังกฤษเป็นฉบับอ้างอิง (canonical)** หากฉบับแปลตามไม่ทันหรือไม่ตรงกัน
  ให้ยึดไฟล์ภาษาอังกฤษ ผู้ที่แก้ไฟล์ภาษาอังกฤษต้องอัปเดตฉบับแปลทั้งสามใน
  การแก้ไขเดียวกัน — เอกสารเหล่านี้ตั้งใจทำให้สั้นเพื่อให้ต้นทุนนี้ต่ำ
- เอกสารสำหรับนักพัฒนา ([CONTRACT.md](CONTRACT.md), ทุกอย่างใต้
  [docs/](docs/), README ของแต่ละ collector) เป็นภาษาอังกฤษเท่านั้น
