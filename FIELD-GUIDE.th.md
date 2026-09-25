# WhaTap Groundtruth — คู่มือภาคสนาม

> **Languages:** [English (canonical)](FIELD-GUIDE.md) · [Bahasa Indonesia](FIELD-GUIDE.id.md) · ไทย · [한국어](FIELD-GUIDE.ko.md)

คู่มือนี้จัดทำสำหรับ **วิศวกรภาคสนาม (field engineer)** — ผู้ที่อยู่หน้างานติดกับ
ระบบของลูกค้า โดยอธิบายว่าเหตุใด WhaTap อาจขอให้คุณรัน *collector*
และวิธีรันอย่างละเอียดทีละขั้น คุณไม่จำเป็นต้องมีความรู้ภายในของ WhaTap
และจะไม่มีการขอให้คุณตีความผลลัพธ์ใด ๆ

## 1. ที่มา — เหตุใดจึงขอให้คุณรันสคริปต์นี้

เมื่อเคส support ไปถึงทีมพัฒนา agent ของ WhaTap นักพัฒนาที่สามารถตีความอาการ
ได้จะอยู่ทางไกล — มักอยู่คนละโซนเวลา — และต้องการข้อเท็จจริงเกี่ยวกับ
สภาพแวดล้อม เช่น ใช้ runtime อะไร, log ถูกเก็บไว้ที่ใดจริง ๆ, โปรเซสรันด้วย
flag อะไรบ้าง การถามทีละข้อผ่านอีเมลหรือแชตต้องเสียเวลาไป-กลับหนึ่งรอบต่อหนึ่ง
คำถาม และเคสที่ต้องการคำตอบสิบข้ออาจเสียเวลาไปสองสัปดาห์กับการถาม-ตอบเช่นนี้

**collector** เข้ามาแทนบทสนทนานั้น คุณรันสคริปต์หนึ่งตัว สคริปต์จะสร้างไฟล์
รายงานหนึ่งไฟล์ แล้วคุณส่งไฟล์นั้นกลับมา รายงานจะมีคำตอบของคำถามที่นักพัฒนา
จะถามอยู่แล้ว — รวมถึงคำถามข้อถัดไปด้วย

สิ่งที่สคริปต์นี้ทำ และไม่ทำ:

- **ค่าเริ่มต้นเป็นแบบอ่านอย่างเดียว (read-only)** การรันแบบมาตรฐานจะไม่แก้ไข
  การตั้งค่าใด ๆ ไม่ restart อะไร และไม่เกาะติดกับโปรเซสใด ถูกออกแบบให้
  ปลอดภัยแม้บนเซิร์ฟเวอร์ที่กำลังมีปัญหาอยู่แล้ว
- **เก็บเฉพาะข้อเท็จจริง — ไม่มีการวินิจฉัย** รายงานตั้งใจไม่ใส่ข้อสรุปหรือ
  คำแนะนำใด ๆ บรรทัดสุดท้ายเขียนไว้ตรงตัวว่า
  `==== END OF COLLECTION (no diagnosis by design) ====` การตีความเป็นหน้าที่
  ของฝั่ง WhaTap
- **ไม่มีอะไรที่คุณต้องตัดสิน** บรรทัดอย่าง `n/a (permission denied: ...)`
  เป็นเรื่องปกติ — ค่าที่อ่านไม่ได้ก็เป็นข้อเท็จจริงที่มีประโยชน์เช่นกัน
  อย่าพยายาม "แก้" ก่อนส่ง

## 2. การรับ collector

collector อยู่ในรีโพซิทอรี Git:

```sh
git clone https://github.com/whatap/global-groundtruth.git
```

หากมีสำเนาอยู่แล้วและต้องการอัปเดต:

```sh
cd global-groundtruth && git pull
```

หากเซิร์ฟเวอร์ปลายทางไม่มีอินเทอร์เน็ต ให้ clone บนเครื่องทำงานของคุณแล้วคัดลอก
ไฟล์สคริปต์ collector เพียงไฟล์เดียวไปยังเซิร์ฟเวอร์ (scp/SFTP/การโอนไฟล์ —
สิ่งที่ต้องใช้มีเพียงไฟล์ `.sh` หนึ่งไฟล์)

## 3. ใช้ collector ตัวไหน เมื่อใด

ผู้ติดต่อฝั่ง WhaTap จะระบุ collector ที่ต้องรันให้:

| สิ่งที่ WhaTap สอบถาม | สคริปต์ | รันที่ใด |
|---|---|---|
| **backend / collection server** (yard, proxy, gateway, ...) | `collectors/collection-server/collect-collserver.sh` | บนโฮสต์ backend โดยตรง |
| **ZFS** ใต้ data path ของ backend (ขอแยกต่างหาก) | `collectors/collection-server/collect-collzfs.sh` | บนโฮสต์ backend นั้นโดยตรง |
| **MySQL** ของ backend (metadata `account` / `notihub`; ขอแยกต่างหาก) | `collectors/collection-server/collect-collmysql.sh` | บนโฮสต์ MySQL หรือโฮสต์ใดก็ได้ที่ client `mysql` เข้าถึงฐานข้อมูลนั้นได้ |
| การมอนิเตอร์ **Kubernetes** (operator, node agent, master agent, ...) | `collectors/k8s/collect-k8s.sh` | เครื่องใดก็ได้ที่เข้าถึงคลัสเตอร์ผ่าน `kubectl` (หรือ `oc`) — bastion หรือเครื่องทำงานของคุณ **ไม่ใช่** บนโหนดของคลัสเตอร์ |
| **NMS Control Manager** (มอนิเตอร์เครือข่าย) | `collectors/nms/collect-nms.sh` | บนโฮสต์ NMS Control Manager โดยตรง |
| การมอนิเตอร์ **ฐานข้อมูล** (เอเจนต์ DBX/XOS/DMX และ DB ที่ถูกมอนิเตอร์) | `collectors/db/collect-db.sh` (Windows/MSSQL: `collectors/db/windows/collect-db-mssql.ps1`) | บนโฮสต์ของเอเจนต์ DB; หากติดตั้งแยกโฮสต์ ให้รันโฮสต์ละหนึ่งครั้ง |
| การมอนิเตอร์แอปพลิเคชัน **Java** | `collectors/apm/java/collect-apmjava.sh` | บนโฮสต์หรือคอนเทนเนอร์ที่แอปพลิเคชัน Java ทำงาน |
| การมอนิเตอร์แอปพลิเคชัน **Python** | `collectors/apm/python/collect-apmpython.sh` | บนโฮสต์หรือคอนเทนเนอร์ที่แอปพลิเคชัน Python ทำงาน |
| การมอนิเตอร์แอปพลิเคชัน **Node.js** | `collectors/apm/nodejs/collect-apmnodejs.sh` | บนโฮสต์หรือคอนเทนเนอร์ที่แอปพลิเคชัน Node.js ทำงาน |
| การมอนิเตอร์แอปพลิเคชัน **PHP** | `collectors/apm/php/collect-apmphp.sh` | บนโฮสต์หรือคอนเทนเนอร์ที่แอปพลิเคชัน PHP (Apache / PHP-FPM) ทำงาน |
| การมอนิเตอร์แอปพลิเคชัน **.NET** (Windows) | `collectors/apm/dotnet/collect-apmdotnet.ps1` | บนโฮสต์ Windows ที่แอปพลิเคชัน .NET ทำงาน โดยใช้ PowerShell แบบยกระดับสิทธิ์ |

## 4. การรัน

การรัน collector **โดยไม่ใส่อาร์กิวเมนต์จะแสดงเฉพาะข้อความช่วยเหลือ** —
จะไม่มีอะไรเริ่มทำงานโดยไม่ตั้งใจ การเก็บข้อมูลต้องระบุ flag อย่างชัดเจนเสมอ
โดยมาตรฐานคือ `--file`

### 4.1 Collection server (โฮสต์ backend)

```sh
cd global-groundtruth/collectors/collection-server
./collect-collserver.sh --file
# -> whatap-collserver-<host>-<timestamp>.txt
```

ส่งไฟล์ `.txt` ตามชื่อที่สคริปต์แจ้งกลับมา หาก WhaTap ขอ **bundle ฉบับเต็ม**
(log จริง + การตั้งค่า ไฟล์ใหญ่ขึ้น):

```sh
./collect-collserver.sh --bundle
# -> whatap-collserver-<host>-<timestamp>.tar.gz
```

หมายเหตุ:

- **ไม่จำเป็น**ต้องใช้ root ให้รันด้วยสิทธิ์สูงสุดเท่าที่นโยบายปฏิบัติการของคุณ
  อนุญาต — หากสิทธิ์ต่ำกว่านั้นรายงานก็ยังใช้ได้ เพียงแต่จะมีบรรทัด
  `n/a (permission denied)` มากขึ้น
- หากรายงานแสดงไดเรกทอรีหลักของ WhaTap เป็น `n/a` ให้รันใหม่พร้อม
  `--home <path>` เช่น `./collect-collserver.sh --file --home /whatap`
- หากคำถามเจาะจงเรื่อง **ZFS** ใต้ data path ของ backend ทาง WhaTap จะขอ
  collector คู่กันในไดเรกทอรีเดียวกัน (`./collect-collzfs.sh --file`) ด้วย
  เป็นรายงานคนละฉบับ กรุณาส่งทั้งสองไฟล์
- หากคำถามเกี่ยวกับ **MySQL** ของ backend ให้รัน `./collect-collmysql.sh --file`
  บนโฮสต์ MySQL หากฐานข้อมูลต้องล็อกอิน ให้ระบุผ่าน `--defaults-file <my.cnf>`
  หรือปล่อยให้ collector ถามรหัสผ่านบนเทอร์มินัล ห้ามพิมพ์รหัสผ่านลงในบรรทัดคำสั่ง
  เพราะผู้ใช้อื่นบนโฮสต์นั้นอ่านได้

### 4.2 Kubernetes (bastion / เครื่องทำงาน)

```sh
cd global-groundtruth/collectors/k8s
./collect-k8s.sh --file
# -> whatap-k8s-<host>-<timestamp>.txt
```

ส่งไฟล์ `.txt` ตามชื่อที่สคริปต์แจ้งกลับมา หาก WhaTap ขอ **bundle ฉบับเต็ม**
(YAML + log ไฟล์ใหญ่ขึ้น):

```sh
./collect-k8s.sh --bundle
# -> whatap-k8s-<host>-<timestamp>.tar.gz
```

หมายเหตุ:

- หาก kubeconfig ของคุณถูกจำกัดไว้เฉพาะบาง namespace ให้เพิ่ม
  `--namespace <namespace-ของ-whatap>`
- บน bastion ที่เข้าถึงได้หลายคลัสเตอร์ ให้เพิ่ม `--context <ชื่อ-context>`

### 4.3 NMS Control Manager (โฮสต์ของ manager)

```sh
cd global-groundtruth/collectors/nms
./collect-nms.sh --file
# -> whatap-nms-<host>-<timestamp>.txt
```

ส่งไฟล์ `.txt` ที่สคริปต์แจ้งชื่อกลับมา (collector ตัวนี้ยังไม่มีโหมด bundle)

### 4.4 การมอนิเตอร์ฐานข้อมูล (โฮสต์ของเอเจนต์ DB)

```sh
cd global-groundtruth/collectors/db
./collect-db.sh --file
# -> whatap-db-<host>-<timestamp>.txt
```

หมายเหตุ:

- กรณี**ติดตั้งแยกโฮสต์** (เอเจนต์อยู่โฮสต์หนึ่ง ฐานข้อมูลอยู่อีกโฮสต์หนึ่ง)
  ให้รันโฮสต์ละหนึ่งครั้ง — ได้ไฟล์หนึ่งไฟล์ต่อหนึ่งโฮสต์
- หาก WhaTap ขอข้อเท็จจริงที่มีเพียงตัวฐานข้อมูลเท่านั้นที่ตอบได้ (สิทธิ์ของ
  บัญชี พารามิเตอร์ ออบเจ็กต์สำหรับมอนิเตอร์ — ซึ่งเป็นช่องทางเดียวสำหรับ DB
  บนคลาวด์แบบ managed เช่น RDS) ทาง WhaTap จะระบุชุด SQL ของเอนจินคุณใน `sql/`
  ให้รันด้วยไคลเอนต์ DB ที่คุณใช้ประจำ แล้วส่งผลลัพธ์กลับมาด้วย
- บน Windows ที่ใช้ MSSQL ให้ใช้ `windows/collect-db-mssql.ps1` แทน

### 4.5 การมอนิเตอร์แอปพลิเคชัน (โฮสต์หรือคอนเทนเนอร์ของแอปพลิเคชัน)

ให้รัน collector ตามภาษาของแอปพลิเคชัน **ข้างๆ โปรเซสของแอปพลิเคชัน** — หาก
แอปพลิเคชันทำงานเป็นคอนเทนเนอร์ ให้รันภายในคอนเทนเนอร์นั้น

```sh
cd global-groundtruth/collectors/apm/java     # หรือ python / nodejs / php
./collect-apmjava.sh --file
# -> whatap-apmjava-<host>-<timestamp>.txt
```

บน Kubernetes หรือ Docker ให้ส่งสคริปต์เข้าทาง stdin แทนการคัดลอกเข้าไปใน
คอนเทนเนอร์ แล้วรับรายงานออกทาง stdout:

```sh
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt

docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt
```

บน Windows collector ของ .NET เป็นสคริปต์ PowerShell ให้รันใน PowerShell
**แบบ 64 บิตและยกระดับสิทธิ์**:

```powershell
cd global-groundtruth\collectors\apm\dotnet
.\collect-apmdotnet.ps1 -File
# -> whatap-apmdotnet-<HOST>-<UTC>.txt
```

หมายเหตุ:

- หากนโยบายอนุญาต ให้รันด้วย**ผู้ใช้ระบบปฏิบัติการเดียวกับโปรเซสของ
  แอปพลิเคชัน** หากรันด้วยผู้ใช้อื่นรายงานก็ยังใช้ได้ เพียงแต่จะมีบรรทัด
  `n/a (permission denied)` มากขึ้น
- WhaTap อาจขอให้รันอีกครั้งพร้อม flag เพิ่มเติม เช่น `--library <ชื่อ>` เพื่อดู
  รายละเอียดของไลบรารีหนึ่งตัว หรือ `--threads` เพื่อเก็บ thread dump โดยจะระบุ
  flag เหล่านั้นให้อย่างชัดเจน ส่วนการรัน `--file` ตามปกติจะไม่แตะต้องโปรเซส
  ของแอปพลิเคชันเลย

### 4.6 ระหว่างที่สคริปต์ทำงาน

- บรรทัดแสดงความคืบหน้าที่ขึ้นต้นด้วย `>> ` จะปรากฏบนเทอร์มินัลให้เห็นว่า
  สคริปต์กำลังทำงาน บรรทัดเหล่านี้ไม่ใช่ส่วนหนึ่งของรายงาน
- การรันใช้เวลาไม่กี่วินาทีจนถึงไม่กี่นาทีบนโฮสต์ที่ช้า รอให้จบ — รายงานจะจบด้วย
  บรรทัด `==== END OF COLLECTION ... ====` เสมอ
- บรรทัด `n/a (...)` ในรายงานเป็นเรื่องปกติ ส่งไฟล์ตามสภาพที่ได้
- **บรรทัด `>> status:` บรรทัดสุดท้าย** บอกว่าการรันครั้งนี้ได้สิ่งที่ต้องการหรือไม่
  - `status: COMPLETE` — ส่งไฟล์ได้เลย
  - `status: INCOMPLETE` — บรรทัดด้านล่างจะระบุสิ่งที่ถูกบล็อกและวิธีรันแบบอื่นที่จะได้ค่านั้น
    เช่น `run again with sudo` หรือ `rerun with --home <dir>` หากนโยบายของคุณอนุญาต
    ให้ทำตามแล้วส่งไฟล์ใหม่ หากไม่อนุญาต ให้ส่งไฟล์ตามสภาพที่ได้ รายงานระบุไว้แล้วว่า
    อ่านอะไรไม่ได้ และ WhaTap จะดำเนินการต่อจากนั้น
- collector ของ Kubernetes, NMS, ฐานข้อมูล และ collection server ต้องใช้ `bash`
  ให้รันตามที่แสดงไว้ (`./collect-...sh`) หากรันด้วย `sh collect-...sh` จะหยุดทันที
  และแจ้งเหตุผล

## 5. การส่งกลับ

- แนบ **ไฟล์ทั้งไฟล์** ตามที่สร้างขึ้นทุกประการ (`.txt` หรือ `.tar.gz`
  สำหรับ bundle) ห้ามแก้ไข ตัดทอน เปลี่ยนชื่อ หรือคัดลอกมาเพียงบางส่วน
- หากถูกขอให้เก็บจากหลายโฮสต์หรือหลายคลัสเตอร์ ให้ส่งหนึ่งไฟล์ต่อหนึ่งโฮสต์ —
  ชื่อไฟล์มี hostname และ timestamp แบบ UTC อยู่แล้ว จึงไม่ชนกัน

## 6. ข้อควรระวังด้านความปลอดภัย

รายงานและ bundle ยกสิ่งที่อ่านได้มาแบบ **ตรงตามต้นฉบับ (verbatim)** — ไม่มีการปิดบัง
ตามนโยบายของ framework: ค่าอย่าง license key หรือ community string ต้องอ่านได้
จึงจะตรวจสอบยืนยันหรือหักล้างได้ ดังนั้นรายงานอาจมีข้อมูลลับอยู่ ส่งไฟล์ผ่านช่องทางที่
เชื่อถือได้ และลบสำเนาในเครื่องเมื่อปิดเคสแล้ว

แหล่งที่ข้อมูลลับอาจเข้ามาได้ แยกตาม collector (รายการเต็มอยู่ใน README ของแต่ละ
collector):

| Collector | อาจมี |
|---|---|
| collection server | `conf/*.conf` (license, `admin.password`, access key), `ps aux` ใน bundle, heap dump |
| MySQL | ตัวแปรของเซิร์ฟเวอร์และรายการโปรเซส ไม่มีรหัสผ่านที่คุณให้ไว้ |
| ZFS | `zpool history` (คำสั่งที่เคยรันกับ pool) |
| Kubernetes | ค่า environment ของ pod และ workload, `helm get values`, environment ของ operator สำหรับ Secret ของ Kubernetes จะอ่านเฉพาะ `cert.pem` สาธารณะของ webhook และแสดงเป็น fingerprint เท่านั้น |
| NMS | การตั้งค่า NMS (access key, SNMP community), ไฟล์ repository ที่อาจมี `user:password@` |
| ฐานข้อมูล | `whatap.conf` (license, `aws_secret_key`, `connect_option`), JDBC URL, บรรทัด cron ที่กล่าวถึง WhaTap |
| Java / Python / Node.js / PHP / .NET | การตั้งค่า agent, environment และบรรทัดคำสั่งของโปรเซสแอปพลิเคชัน, การตั้งค่า process manager (เช่น `ecosystem.config.js`) |

collector จะไม่นำข้อมูลรับรองที่คุณให้ไว้ไปใส่ในบรรทัดคำสั่ง และ collector ของ MySQL
จะไม่เขียนรหัสผ่านลงในรายงาน

## 7. ภาษา

- คู่มือนี้จัดทำเป็นภาษาอังกฤษ (ฉบับอ้างอิง/canonical) ภาษาอินโดนีเซีย ภาษาไทย
  และภาษาเกาหลี หากฉบับแปลไม่ตรงกัน ให้ยึดฉบับภาษาอังกฤษเป็นหลัก
- **ผลลัพธ์ของรายงานและข้อความทั้งหมดของสคริปต์เป็นภาษาอังกฤษเสมอโดยตั้งใจ** —
  มีเครื่องมือที่ parse ข้อความตามตัวอักษร ห้ามแปลหรือแก้ไขเอาต์พุตของสคริปต์

## 8. การติดต่อสอบถาม

หากมีข้อสงสัย หรือ collector รันไม่สำเร็จ: ติดต่อทีม WhaTap Global
(ผู้ติดต่อฝ่าย support ของ WhaTap ที่คุณใช้ประจำ) พร้อมแนบภาพหน้าจอหรือสำเนา
เอาต์พุตจากเทอร์มินัล — เอาต์พุตนั้นเองก็เป็นหลักฐานที่มีประโยชน์
