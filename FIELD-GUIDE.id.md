# WhaTap Groundtruth — Panduan Lapangan

> **Languages:** [English (canonical)](FIELD-GUIDE.md) · Bahasa Indonesia · [ไทย](FIELD-GUIDE.th.md) · [한국어](FIELD-GUIDE.ko.md)

Panduan ini ditujukan bagi **engineer lapangan** — orang yang berada langsung
di sisi sistem pelanggan. Panduan ini menjelaskan mengapa WhaTap mungkin
meminta Anda menjalankan sebuah *collector*, dan bagaimana tepatnya
menjalankannya. Anda tidak memerlukan pengetahuan internal WhaTap, dan Anda
tidak pernah diminta menafsirkan hasilnya.

## 1. Latar belakang — mengapa Anda diminta menjalankan ini

Ketika sebuah kasus support sampai ke tim pengembang agent WhaTap, developer
yang dapat menafsirkan gejala berada di lokasi lain — sering kali di zona
waktu berbeda — dan membutuhkan fakta tentang lingkungan: runtime apa yang
dipakai, di mana log sebenarnya tersimpan, dengan flag apa proses berjalan.
Menanyakan hal-hal itu satu per satu lewat email atau chat memakan satu kali
bolak-balik per pertanyaan, dan kasus yang membutuhkan sepuluh jawaban bisa
kehilangan dua minggu hanya untuk tanya-jawab tersebut.

Sebuah **collector** menggantikan dialog itu. Anda menjalankan satu skrip;
skrip menghasilkan satu file laporan; Anda mengirimkan kembali file tersebut.
Laporan itu sudah berisi jawaban atas pertanyaan yang akan diajukan developer —
termasuk pertanyaan lanjutannya.

Apa yang dilakukan skrip ini, dan apa yang tidak:

- **Secara default hanya membaca (read-only).** Eksekusi default tidak
  mengubah konfigurasi apa pun, tidak me-restart apa pun, dan tidak menempel
  ke proses mana pun. Skrip ini dirancang agar aman bahkan pada server yang
  sedang bermasalah.
- **Hanya fakta — tanpa diagnosis.** Laporan sengaja tidak berisi kesimpulan
  atau rekomendasi; baris terakhirnya secara harfiah berbunyi
  `==== END OF COLLECTION (no diagnosis by design) ====`. Interpretasi
  dilakukan di sisi WhaTap.
- **Tidak ada yang perlu Anda nilai.** Baris seperti
  `n/a (permission denied: ...)` adalah hal normal — nilai yang tidak dapat
  dibaca juga merupakan fakta yang berguna. Jangan mencoba "memperbaikinya"
  sebelum mengirim.

## 2. Mendapatkan collector

Collector tersimpan di sebuah repositori Git:

```sh
git clone https://github.com/whatap/global-groundtruth.git
```

Untuk memperbarui salinan yang sudah Anda miliki:

```sh
cd global-groundtruth && git pull
```

Jika server target tidak memiliki akses internet, lakukan clone di
workstation Anda lalu salin satu file skrip collector ke server
(scp/SFTP/transfer file — yang dibutuhkan hanya satu file `.sh`).

## 3. Collector mana, untuk kasus apa

Kontak WhaTap Anda akan menyebutkan collector yang harus dijalankan:

| Yang ditanyakan WhaTap | Skrip | Dijalankan di mana |
|---|---|---|
| **Backend / collection server** (yard, proxy, gateway, ...) | `collectors/collection-server/collect-collserver.sh` | langsung di host backend |
| **ZFS** di bawah data path backend (diminta secara terpisah) | `collectors/collection-server/collect-collzfs.sh` | langsung di host backend tersebut |
| Monitoring **Kubernetes** (operator, node agent, master agent, ...) | `collectors/k8s/collect-k8s.sh` | mesin mana pun yang dapat menjangkau cluster lewat `kubectl` (atau `oc`) — bastion atau workstation Anda, **bukan** di node cluster |
| **NMS Control Manager** (monitoring jaringan) | `collectors/nms/collect-nms.sh` | langsung di host NMS Control Manager |
| Monitoring **database** (agen DBX/XOS/DMX dan DB yang dimonitor) | `collectors/db/collect-db.sh` (Windows/MSSQL: `collectors/db/windows/collect-db-mssql.ps1`) | di host agen DB; untuk instalasi terpisah, satu kali di setiap host |
| Monitoring aplikasi **Java** | `collectors/apm/java/collect-apmjava.sh` | di host atau container tempat aplikasi Java berjalan |
| Monitoring aplikasi **Python** | `collectors/apm/python/collect-apmpython.sh` | di host atau container tempat aplikasi Python berjalan |
| Monitoring aplikasi **Node.js** | `collectors/apm/nodejs/collect-apmnodejs.sh` | di host atau container tempat aplikasi Node.js berjalan |
| Monitoring aplikasi **PHP** | `collectors/apm/php/collect-apmphp.sh` | di host atau container tempat aplikasi PHP (Apache / PHP-FPM) berjalan |
| Monitoring aplikasi **.NET** (Windows) | `collectors/apm/dotnet/collect-apmdotnet.ps1` | di host Windows tempat aplikasi .NET berjalan, dalam PowerShell dengan hak administrator |

## 4. Menjalankannya

Menjalankan collector **tanpa argumen hanya menampilkan bantuan** — tidak ada
yang dimulai secara tidak sengaja. Pengumpulan selalu membutuhkan flag
eksplisit; yang standar adalah `--file`.

### 4.1 Collection server (host backend)

```sh
cd global-groundtruth/collectors/collection-server
./collect-collserver.sh --file
# -> whatap-collserver-<host>-<timestamp>.txt
```

Kirimkan kembali file `.txt` yang disebutkan skrip. Jika WhaTap meminta
**bundle lengkap** (log asli + konfigurasi, file lebih besar):

```sh
./collect-collserver.sh --bundle
# -> whatap-collserver-<host>-<timestamp>.tar.gz
```

Catatan:

- Root **tidak wajib**. Jalankan dengan hak akses tertinggi yang diizinkan
  kebijakan operasional Anda — dengan hak akses lebih rendah laporan tetap
  valid, hanya berisi lebih banyak baris `n/a (permission denied)`.
- Jika laporan menampilkan direktori home WhaTap sebagai `n/a`, jalankan ulang
  dengan `--home <path>`, misalnya `./collect-collserver.sh --file --home /whatap`.
- Bila pertanyaannya khusus tentang **ZFS** di bawah data path backend, WhaTap
  akan meminta collector pendamping di direktori yang sama
  (`./collect-collzfs.sh --file`). Itu laporan terpisah; kirim keduanya.

### 4.2 Kubernetes (bastion / workstation)

```sh
cd global-groundtruth/collectors/k8s
./collect-k8s.sh --file
# -> whatap-k8s-<host>-<timestamp>.txt
```

Kirimkan kembali file `.txt` yang disebutkan skrip. Jika WhaTap meminta
**bundle lengkap** (YAML + log, file lebih besar):

```sh
./collect-k8s.sh --bundle
# -> whatap-k8s-<host>-<timestamp>.tar.gz
```

Catatan:

- Jika kubeconfig Anda dibatasi pada namespace tertentu, tambahkan
  `--namespace <namespace-whatap>`.
- Pada bastion yang menjangkau beberapa cluster, tambahkan
  `--context <nama-context>`.

### 4.3 NMS Control Manager (host manager)

```sh
cd global-groundtruth/collectors/nms
./collect-nms.sh --file
# -> whatap-nms-<host>-<timestamp>.txt
```

Kirim kembali file `.txt` yang disebutkannya. (Collector ini belum memiliki mode bundle.)

### 4.4 Monitoring database (host agen DB)

```sh
cd global-groundtruth/collectors/db
./collect-db.sh --file
# -> whatap-db-<host>-<timestamp>.txt
```

Catatan:

- Untuk **instalasi terpisah** (agen di satu host, database di host lain),
  jalankan satu kali di setiap host — satu file per host.
- Jika WhaTap juga meminta fakta yang hanya dapat dijawab oleh database itu
  sendiri (grant, parameter, objek monitoring — satu-satunya jalur untuk DB
  cloud terkelola seperti RDS), mereka akan menyebutkan paket SQL untuk engine
  Anda di `sql/`. Jalankan dengan klien DB yang biasa Anda pakai dan kirim
  hasilnya juga.
- Di Windows dengan MSSQL, gunakan `windows/collect-db-mssql.ps1`.

### 4.5 Monitoring aplikasi (host atau container aplikasi)

Jalankan collector sesuai bahasa aplikasi, **di sebelah proses aplikasi** — di
dalam container bila aplikasi dijalankan sebagai container.

```sh
cd global-groundtruth/collectors/apm/java     # atau python / nodejs / php
./collect-apmjava.sh --file
# -> whatap-apmjava-<host>-<timestamp>.txt
```

Di Kubernetes atau Docker, alirkan skrip lewat stdin alih-alih menyalinnya ke
dalam container, lalu ambil laporannya dari stdout:

```sh
kubectl exec -i <pod> -c <container> -- sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt

docker exec -i <container> sh -s -- --stdout --quiet \
    < collect-apmjava.sh > report.txt
```

Di Windows, collector .NET berupa skrip PowerShell — jalankan di PowerShell
**64-bit dengan hak administrator**:

```powershell
cd global-groundtruth\collectors\apm\dotnet
.\collect-apmdotnet.ps1 -File
# -> whatap-apmdotnet-<HOST>-<UTC>.txt
```

Catatan:

- Jalankan sebagai **user OS yang sama dengan proses aplikasi** bila kebijakan
  Anda mengizinkan. Dengan user lain laporan tetap valid, hanya dengan lebih
  banyak baris `n/a (permission denied)`.
- WhaTap mungkin meminta satu kali jalan lagi dengan flag tambahan — misalnya
  `--library <nama>` untuk merinci satu library, atau `--threads` untuk thread
  dump. Flag tersebut akan disebutkan secara eksplisit; jalan `--file` biasa
  tidak pernah menyentuh proses aplikasi.

### 4.6 Selama skrip berjalan

- Baris progres yang diawali `>> ` muncul di terminal sehingga Anda dapat
  melihat skrip bekerja; baris itu bukan bagian dari laporan.
- Eksekusi memakan waktu beberapa detik hingga beberapa menit pada host yang
  lambat. Biarkan sampai selesai — laporan selalu diakhiri baris
  `==== END OF COLLECTION ... ====`.
- Baris `n/a (...)` di dalam laporan adalah hal yang wajar. Kirim file apa
  adanya.

## 5. Mengirimkan kembali

- Lampirkan **file utuh** persis seperti yang dihasilkan (`.txt`, atau
  `.tar.gz` untuk bundle). Jangan mengedit, memotong, mengganti nama, atau
  menempelkan potongan.
- Diminta mengumpulkan dari beberapa host atau cluster? Satu file per host —
  nama file sudah memuat hostname dan timestamp UTC sehingga tidak akan
  saling bertabrakan.

## 6. Catatan keamanan

- Semua laporan dan bundle memuat konfigurasi **apa adanya (verbatim)** —
  tanpa masking, sesuai kebijakan framework: nilai seperti license key atau
  community string harus terbaca agar bisa diverifikasi atau dibantah.
  `secure.conf`, password admin, dan access key tampil apa adanya. Kirim
  lewat jalur tepercaya dan hapus salinan lokal setelah kasus ditutup.
- Collector **k8s** tidak pernah mengambil isi Secret Kubernetes (hanya
  tabel nama/tipe) — tetapi selebihnya, termasuk log di dalam bundle,
  verbatim. Perlakukan dengan kehati-hatian yang sama.

## 7. Bahasa

- Panduan ini dikelola dalam bahasa Inggris (acuan/canonical), bahasa
  Indonesia, bahasa Thai, dan bahasa Korea. Jika terjemahan berbeda, versi
  bahasa Inggris yang berlaku.
- **Output laporan dan semua pesan skrip selalu dalam bahasa Inggris, memang
  dirancang demikian** — ada tool yang mem-parsing string persisnya. Jangan
  menerjemahkan atau mengubah output skrip.

## 8. Pertanyaan

Jika ada yang kurang jelas, atau collector gagal berjalan: hubungi tim WhaTap
Global (kontak support WhaTap Anda yang biasa) dengan menyertakan screenshot
atau salinan output terminal — output itu sendiri merupakan bukti yang
berguna.
