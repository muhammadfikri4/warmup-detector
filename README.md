# WarmUp Pulse (watchOS 27 + iPhone companion)

Implementasi Swift dari PRD **WarmUp Pulse / ReadyMove v2.0** — validasi kesiapan fisiologis
otomatis saat menekan *Start Workout*, dengan arsitektur **Sensor → Prediction → Interpretation**.

```
WarmUpPulse.xcodeproj            Project Xcode: app iPhone (iOS 27) yang meng-embed app watch (watchOS 27), Swift 6
WarmUpPulse iOS/                 Companion: pengaturan, data, training manual (Latih Ulang), evaluasi
WarmUpPulse Watch App/
  App/            AppFlow (state machine PRD §2), AppSettings, entry point
  Sensor/         HKWorkoutSession + LiveWorkoutBuilder, query HealthKit, CoreMotion 50 Hz
  Prediction/     CoreML classifier (dinamis), MotionPipeline, perekam data latih
  Interpretation/ Apple Intelligence (Foundation Models), haptik, Text-to-Speech
  UI/             Layar SwiftUI (oranye → hijau, tipografi ≥ 24 pt)
Packages/WarmUpCore/             Logika murni + unit test (jalan di Mac: `swift test`)
  Sources/WarmUpTrain/           `warmup-train`: pipeline data gerak → WarmUpClassifier.mlmodel
  Sources/WarmUpEval/            `warmup-eval`: evaluasi kesiapan vs referensi dari log Mode Studi
Config/                          Info.plist (workout-processing) & entitlement HealthKit
```

## Peran iPhone vs Apple Watch

| | iPhone (companion) | Apple Watch |
|---|---|---|
| Pengaturan | **Sumber kebenaran**: AI, suara, zona HR, Mode Studi, partisipan, consent, skenario, rekam otomatis | Menerapkan & menampilkan (baca-saja) |
| Data | Menerima CSV & log sesi, ekspor (ShareLink) | Merekam (manual / otomatis), mengirim ke iPhone |
| Training | **Pemicu manual "Latih Ulang"** → evaluasi → "Kirim ke Watch" | Memakai model kiriman (prioritas: model iPhone → CoreML bawaan → heuristik) |
| Evaluasi | Laporan sensitivity/PPV kesiapan | Mencatat log sesi (Mode Studi) |

Sinkronisasi memakai WatchConnectivity: pengaturan lewat *application context* (versi terbaru selalu menang,
sampai walau app watch sedang tertutup), model & log lewat *user info* (antrean, tidak hilang), CSV lewat *file transfer*.
Rekaman otomatis dihapus dari watch setelah sampai di iPhone.

**Kenapa logistic regression di iPhone?** iOS tidak menyediakan `MLActivityClassifier` (training CreateML gerakan
hanya di Mac), dan watchOS tidak bisa mengompilasi model Core ML saat app berjalan. Logistic regression
(`WarmUpCore/SoftmaxClassifier.swift`, 29 fitur per jendela 2 dtk) dilatih di iPhone dan dikirim sebagai JSON kecil.
Jalur CreateML di Mac (`warmup-train`) tetap tersedia sebagai pembanding/opsi lanjutan.

## Menjalankan

1. Buka `WarmUpPulse.xcodeproj` di Xcode 27.
2. Untuk **kedua** target (*WarmUpPulse* dan *WarmUpPulse Watch App*) › *Signing & Capabilities*: pilih **Team**.
   Ganti bundle ID secara berpasangan, mis. `com.kamu.warmuppulse` dan `com.kamu.warmuppulse.watchkitapp`,
   lalu samakan `INFOPLIST_KEY_WKCompanionAppBundleIdentifier` di target watch dengan bundle ID iPhone.
   Capability HealthKit watch ada di `Config/WarmUpPulse.entitlements`.
3. Jalankan scheme **WarmUpPulse** ke iPhone (app watch ikut terpasang di watch yang dipasangkan), atau scheme
   **WarmUpPulse Watch App** langsung ke watch.
   Di simulator, HR & gerakan tidak realistis — uji alur penuh di Apple Watch asli.

Unit test logika inti (skenario Evaluation Matrix PRD §5):

```bash
cd Packages/WarmUpCore && swift test
```

## Pemetaan PRD → kode

| PRD | Implementasi |
|---|---|
| FR-S01 Session Init | `Sensor/WorkoutSessionManager.swift` — satu sesi untuk seluruh alur; pemanasan dicatat sebagai sub-aktivitas (`beginNewActivity`) |
| FR-S02 HR stream + riwayat 10 mnt | `WorkoutSessionManager` (live) + `HealthDataService.heartRates/activeEnergy` |
| FR-S03 CoreMotion 50 Hz | `Sensor/MotionSampler.swift` (userAcceleration, rotationRate, gravity) |
| FR-S04 RHR, tidur, usia | `HealthDataService.recoveryContext` |
| FR-P01 Readiness ≤ 3 dtk | `WarmUpCore/ReadinessEngine.swift` — Karvonen + deteksi tren kenaikan bertahap |
| FR-P02 Alert + Mulai/Lewati | `AppFlow.presentUnready` + `UnreadyView` (`.notification`) |
| FR-P03 Klasifikasi gerakan 2 dtk | `CoreMLMotionClassifier` (model CreateML) / `HeuristicMotionClassifier` (fallback) |
| FR-P04 Anti-cheat ≥ 80%, idle > 5 dtk | `WarmUpCore/GuidedWarmUpEngine.swift` |
| FR-P05 `.success` + transisi otomatis | `AppFlow.handle` — haptik sukses, cue suara gerakan berikutnya |
| FR-P06 Konfirmasi akhir | `AppFlow.confirmReadiness` (tunggu ≤ 45 dtk; opsi +1 menit / mulai sekarang) |
| FR-I01–I03 Kalibrasi, penjelasan, urutan & cue | `WarmUpPlanner` (rule-based) + `CoachService` (Apple Intelligence) |
| FR-I04 Ringkasan | `WarmUpSummary` + `CoachService.summaryNote` → metadata workout |
| NFR-01 Matikan sensor | `AppFlow.finishWarmUp/stopMotion` |
| NFR-02 On-device < 200 ms | Inferensi di antrean motion (bukan main thread); latensi ditampilkan di layar pemanasan |
| NFR-03 Akurasi ≥ 85% | `warmup-train` gagal (exit 1) bila akurasi leave-one-person-out < 85% |
| NFR-04 Guardrail | `SafetyGuardrail` (instruksi + filter istilah medis) + planner memvalidasi keluaran AI |
| NFR-05 Glanceable | `UI/FlowViews.swift` — 24 pt / 52 pt, oranye → hijau |

## Pipeline data: dari data mentah ke hasil yang bisa dipercaya

| Tahap | Gerakan (classifier) | Kesiapan (readiness) |
|---|---|---|
| **1. Collect** | Layar *Rekam Data Latih*: kode partisipan samaran (P01–P30), pergelangan, centang persetujuan → CSV `<label>_<P01>_<L\|R>_<epoch>.csv` | *Pengaturan › Mode Studi*: partisipan + **skenario referensi** dipilih peneliti sebelum Start → `Documents/evaluation/sessions.jsonl` |
| **2. Clean** | `warmup-train` menolak rekaman rusak (< 5 dtk, < 40 Hz, sampel hilang > 5%, NaN) dan memotong 1 dtk awal/akhir | `HeartRateCleaner`: rentang 35–220 bpm, buang spike terisolasi, celah > 150 dtk dicatat (tidak diisi) dan ditampilkan |
| **3. Features** | CreateML belajar dari 6 kanal mentah (akselerasi + rotasi), jendela 2 dtk | RHR & HRV (SDNN) dibandingkan **baseline pribadi** 30 hari; tren HR 10 menit |
| **4. Model** | Baseline heuristik vs CreateML pada data uji yang sama | Skor/aturan Karvonen (sengaja sederhana) |
| **5. Evaluate** | **Leave-one-person-out**, sensitivity & PPV per gerakan, confusion matrix | `warmup-eval`: sensitivity/PPV/specificity vs skenario, per partisipan, latensi ≤ 3 dtk, hitungan repetisi vs hitungan manual |

Nama asli partisipan tidak pernah disimpan. Simpan daftar kode ↔ nama (bila perlu) terpisah dari data.

### Melatih classifier gerakan di iPhone (alur utama)

1. iPhone › **Pengaturan**: pilih partisipan, pergelangan, centang *consent*. Opsional: *Rekam otomatis saat pemanasan*.
2. Watch: **Rekam Data Latih** (manual, label kuat) dan/atau lakukan pemanasan terpandu (otomatis, label lemah = gerakan
   yang diinstruksikan, bobot 0,5). Data otomatis berasal dari instruksi, **bukan** dari prediksi model, supaya model tidak
   "mengajari dirinya sendiri".
3. iPhone › **Data**: cek jumlah rekaman per partisipan & label.
4. iPhone › **Model**: (opsional) pilih **golden set** — partisipan yang dikunci khusus pengujian — lalu **Latih Ulang**.
5. Bila akurasi ≥ 85% dan tidak lebih buruk dari model aktif pada data uji yang sama, tombol **Kirim ke Watch** muncul.
   *Kembali ke model bawaan* membatalkannya.

### Melatih classifier gerakan di Mac (CreateML, opsional)

1. Di jam: **Rekam Data Latih** → pilih partisipan, pergelangan, centang *Partisipan setuju* → pilih label → *Rekam*.
   Label: `armCircles`, `marchInPlace`, `torsoTwist`, `idle`, `other` (gerakan acak). Target ≥ 5 sesi per label per
   partisipan, ≥ 3 partisipan, kedua pergelangan. Layar perekam menampilkan jumlah rekaman per label.
2. Ambil CSV: iPhone › Data › **Ekspor**, atau Xcode › *Download Container* → `AppData/Documents/training/`.
3. Latih + evaluasi:
   ```bash
   swift run --package-path Packages/WarmUpCore warmup-train path/ke/training "WarmUpPulse Watch App/WarmUpClassifier.mlmodel"
   ```
   Output: rekaman yang ditolak beserta alasannya, akurasi per fold (per orang), sensitivity & PPV per gerakan untuk
   baseline heuristik dan CreateML, lalu model final dari semua data. Exit 1 bila akurasi < 85%.
4. Build ulang app; cek *Pengaturan › Classifier gerakan*.

### Mengevaluasi kesiapan

1. iPhone › *Pengaturan › Mode Studi* → aktifkan, pilih partisipan, centang persetujuan.
2. Sebelum tiap sesi, pilih skenario di iPhone: **Dingin** (duduk 5 mnt) atau **Hangat** (jalan cepat 6 mnt), lalu Start.
   Skenario otomatis kembali ke "Tidak diketahui" setelah sesi tercatat.
3. Di layar akhir, isi **hitungan manual** repetisi (dari hitungan peneliti/video) → *Simpan & Selesai*.
4. Laporan langsung terlihat di iPhone › **Evaluasi**. Untuk analisis di Mac, ekspor `sessions.jsonl` lalu:
   ```bash
   swift run --package-path Packages/WarmUpCore warmup-eval path/ke/sessions.jsonl
   ```
   Positif = "Belum Pemanasan". **Sensitivity**: dari yang benar-benar belum pemanasan, berapa yang tertangkap.
   **PPV**: dari peringatan "Belum Pemanasan", berapa yang benar.

## Keputusan desain yang perlu diketahui

- **Foundation Models di watchOS 27**: `SystemLanguageModel` (on-device) *tidak tersedia* di watchOS;
  yang tersedia `PrivateCloudComputeLanguageModel` (server Apple Private Cloud Compute, bukan pihak ketiga).
  Karena itu teks template deterministik selalu tampil instan lebih dulu, AI hanya menyempurnakan bila
  diizinkan (toggle di Pengaturan, default **aktif**), dan yang dikirim hanya angka ringkas tanpa identitas.
  Alternatif bila ingin 100% on-device: jalankan Foundation Models di iPhone companion via WatchConnectivity.
- **Zona HR**: default Karvonen 50–70% HRR dengan Max HR Tanaka (208 − 0,7 × usia). Untuk usia 30 / RHR 65,
  batas bawahnya 126 bpm — cukup tinggi untuk dicapai dengan 3 menit pemanasan ringan. Karena itu ada
  (a) jalur "tren kenaikan bertahap" (≥ 3 menit di atas 30% HRR, tren ≥ 1,5 bpm/mnt, atau Active Energy ≥ 20 kkal),
  (b) pilihan metode `% Max HR` di Pengaturan, dan (c) opsi "Tambah 1 Menit / Mulai Sekarang" bila konfirmasi akhir
  tidak tercapai dalam 45 detik. Ambang-ambang ini sebaiknya dikalibrasi dengan data uji nyata.
- **Hitung repetisi**: classifier menentukan *jenis* gerakan (gerbang anti-cheat), sedangkan repetisi dihitung
  dari siklus sinyal (gravitasi untuk Arm Circles, yaw-rate untuk Torso Twist); March in Place berbasis durasi.
- **Belum termasuk**: pemulihan sesi workout setelah app crash; training otomatis (pemicu sengaja manual di iPhone).

## Signing per developer

A bundle ID can only be owned by one Apple team, so each developer uses their own prefix. Defaults are in `Config/Signing.xcconfig`. Each Mac overrides them in `Config/Local.xcconfig`, which is git-ignored.

```bash
./scripts/setup-signing.sh albertus        # Team ID read automatically from the keychain
./scripts/setup-signing.sh albertus ABCDE12345   # or pass the Team ID yourself
```

Then run on a physical device:

```bash
./scripts/run-iphone.sh    # iPhone (the watch app is embedded)
./scripts/run-watch.sh     # Apple Watch (the Mac must be able to see the watch)
```

Do not change the Team or bundle ID under Signing & Capabilities in Xcode. That writes to `project.pbxproj` and overrides the setting for every other developer.
