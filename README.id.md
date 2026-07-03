# WhaTap Global Groundtruth

> **Languages:** [English (canonical)](README.md) · Bahasa Indonesia · [ไทย](README.th.md) · [한국어](README.ko.md)
>
> **Anda engineer lapangan?** Anda tidak perlu membaca seluruh halaman ini.
> Bacalah **[Panduan Lapangan](FIELD-GUIDE.id.md)**
> ([English](FIELD-GUIDE.md) · [ไทย](FIELD-GUIDE.th.md) · [한국어](FIELD-GUIDE.ko.md))
> — berisi latar belakang, perintah yang persis, dan apa yang harus dikirim
> kembali.

Sebuah **framework diagnostic collector** multi-domain untuk support WhaTap.

Setiap *collector* mengumpulkan fakta lingkungan tersembunyi yang dibutuhkan
developer agent WhaTap di lokasi lain, sehingga engineer lapangan cukup
menjalankan **satu perintah** dan menyerahkan **satu laporan lengkap**. Ini
menghilangkan tanya-jawab diagnostik bolak-balik — masalah "dua puluh
pertanyaan" — yang memperlambat kasus support di domain K8s, server, APM,
dan DB.

## Latar belakang

Kasus support jarak jauh biasanya tersendat pada fakta lingkungan, bukan pada
analisis. Developer yang mampu menafsirkan gejala berada jauh dari sistem yang
menunjukkannya; engineer yang berada di sisi sistem tidak mungkin tahu lebih
dulu fakta mana — dari ribuan fakta — yang akan dibutuhkan developer. Maka
kasus berjalan sebagai dialog satu-pertanyaan-per-hari — "runtime apa?",
"log sebenarnya tersimpan di mana?", "JVM berjalan dengan flag apa?" — yang
semakin panjang karena zona waktu dan relay chat. Sepuluh pertanyaan bisa
menghabiskan dua minggu waktu kalender untuk satu jam pekerjaan nyata.

Sebuah collector menggantikan dialog itu dengan satu artefak: engineer
lapangan menjalankan satu skrip dan mengirimkan kembali satu file yang sudah
menjawab pertanyaan-pertanyaan yang akan diajukan developer — termasuk
pertanyaan lanjutannya. Namanya menyatakan tujuannya: setiap laporan adalah
**ground truth** tentang lingkungan — fakta hasil observasi, tanpa
interpretasi.

## Mengapa berbentuk framework

Pola diagnostiknya berlaku umum lintas domain; **kode** pengumpulannya tidak.
Karena itu repositori ini berisi **contract + format + template + validator**
bersama, ditambah **implementasi per-domain** yang dimiliki masing-masing tim
domain. Satu engineer lapangan, satu perintah, satu paste — dan pembacanya
(developer agent) menerima fakta ground-truth, bukan kuesioner.

## Contract dalam satu tarikan napas

Baca [CONTRACT.md](CONTRACT.md) — empat aturan, tidak bisa ditawar:

1. **Hanya fakta** — tanpa diagnosis, tanpa perkiraan penyebab, tanpa
   rekomendasi, tanpa perbaikan.
2. **Temukan, jangan berasumsi** — resolve symlink/mount/konfigurasi;
   lingkungan baru tidak boleh membutuhkan perubahan kode.
3. **Satu perintah lapangan → paste output** — engineer menjalankan satu hal
   dan menyalin semuanya.
4. **Dimiliki tim domain** — pemilik framework menyediakan kerangkanya; setiap
   collector milik developer domainnya.

Semua laporan berbagi satu bentuk (header → seksi fakta bernomor → footer
tetap): [docs/output-format.md](docs/output-format.md).

## Tata letak repositori

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
│   ├── nms/                      # SEEDED v0 — NMS Control Manager host collector
│   ├── server/                   # STUB (README only)
│   ├── apm/                      # STUB (README only) — one per language: nodejs/java/python/php/dotnet
│   ├── db/                       # STUB (README only)
│   └── collection-server/        # SEEDED v0 — WhaTap backend (yard/proxy/...) collector
├── templates/
│   └── collector-skeleton/       # copy this to start a collector
└── tools/
    └── validate.sh               # lint: enforces facts-only + header + footer
```

## Status collector

| Domain   | Status          | Catatan                                              |
|----------|-----------------|----------------------------------------------------|
| `k8s`               | SEEDED v0       | collector cluster yang dijalankan dari bastion; lihat `collectors/k8s/` |
| `nms`               | SEEDED v0       | skrip host NMS Control Manager; lihat `collectors/nms/` |
| `server`            | NOT IMPLEMENTED | skrip shell host; lihat `collectors/server/`          |
| `apm`               | NOT IMPLEMENTED | keluarga per-bahasa; lihat `collectors/apm/`            |
| `db`                | NOT IMPLEMENTED | SQL + dump konfigurasi agent; lihat `collectors/db/`         |
| `collection-server` | SEEDED v0       | skrip host backend; lihat `collectors/collection-server/` |

Repositori ini memuat **framework**-nya (contract, format, template,
validator, dokumentasi), **stub** per-domain, dan tiga collector **seeded v0**
(`collection-server`, `k8s`, `nms`) yang dimiliki tim Global sampai serah terima.
Collector ditulis lalu dimiliki oleh tim domain masing-masing.

## Menjalankan collector (engineer lapangan)

Mulailah dari **[Panduan Lapangan](FIELD-GUIDE.id.md)** — di sana disebutkan
perintah persis untuk tiap collector. Bentuknya selalu sama: jalankan satu
hal, kirimkan kembali seluruh output. Anda tidak diminta menafsirkan apa pun.
Detail per collector ada di `collectors/<domain>/README.md`.

## Menambah collector (developer domain)

1. Salin [templates/collector-skeleton/](templates/collector-skeleton/) ke
   `collectors/<domain>/`.
2. Isi fakta-faktanya, dengan mematuhi [CONTRACT.md](CONTRACT.md) dan
   [docs/output-format.md](docs/output-format.md).
3. Validasi:
   ```sh
   tools/validate.sh collectors/<domain>/<your-collector>.sh
   ```

Panduan lengkap: [docs/authoring-guide.md](docs/authoring-guide.md). Untuk
collector yang tangguh — seksi MECE, tier aman-beban, portabilitas pada host
tak dikenal, dan `n/a` yang beralasan — ikuti
[docs/collector-engineering.md](docs/collector-engineering.md).

## Kebijakan bahasa dokumentasi

- **Skrip hanya dalam bahasa Inggris** — kode, komentar, teks usage/help,
  narasi progres, dan setiap baris output laporan. Laporan di-parse oleh tool
  dan dibaca developer lintas region; `tools/validate.sh` dan footer sentinel
  yang tetap bergantung pada string bahasa Inggris yang persis. Jangan pernah
  menerjemahkan output laporan.
- **Dokumen untuk lapangan** — [FIELD-GUIDE.md](FIELD-GUIDE.md) dan README
  ini — dikelola dalam empat bahasa: Inggris ditambah bahasa Indonesia
  (`.id.md`), Thai (`.th.md`), dan Korea (`.ko.md`).
- **Bahasa Inggris adalah acuan (canonical).** Jika terjemahan tertinggal atau
  berbeda, file bahasa Inggris yang berlaku. Siapa pun yang mengubah file
  bahasa Inggris memperbarui ketiga terjemahannya dalam perubahan yang sama —
  dokumen-dokumen ini sengaja dibuat pendek agar biayanya murah.
- Dokumen developer ([CONTRACT.md](CONTRACT.md), semua isi [docs/](docs/),
  README tiap collector) hanya dalam bahasa Inggris.
