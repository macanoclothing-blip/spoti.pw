# Analisi: perché la barra del volume si sposta verso l'alto quando premi Pausa

**Data:** 2026-10-15 &nbsp;|&nbsp; **Branch:** `arena/78af061e-spoti-pw` (base `ac07f81 player volume bar bugfixed`) &nbsp;|&nbsp; **Lingua:** IT

---

## 1. Sintesi in 30 secondi

Quando premi **Pausa** nel player ridisegnato la `MPVolumeView` (la barra di volume di sistema che SpotifyGlass inserisce tra i controlli di trasporto e il footer) **non si sposta davvero nel layout dello `UIStackView`**, ma **il suo `UISlider` interno schizza in alto dentro i 44pt della riga**, e contemporaneamente i **controlli di playback (`play / prev / next`) vengono traslati con un `CGAffineTransform`** calcolato dal footer leggendo i `frame` di `volumeRow` e `progressRow`.

Su *pause* succede una **race tra due layout**:

1. **Il `bottomStack` (`npv.bottomStackView`) non ha ancora ricalcolato le `frame` della riga volume** appena (re)inserita da `PlayerVolume.x`. `lowerRow()` in `PlayerFooter.x` legge `volumeRow.frame` quando è ancora `CGRectZero` o con altezza 0 e calcola un `midpoint` sbagliato → i controlli saltano → l'occhio percepisce che *la volume si è mossa verso l'alto* (la distanza tra progress e volume cambia di colpo).
2. **`MPVolumeView` ricrea il suo slider interno quando la sessione audio si disattiva** (ogni `pause`). Per qualche runloop il nuovo slider nasce a `y = 0` (in cima ai 44pt) finché `SGRCenteredVolumeView` non lo ri-centra in `layoutSubviews`. Prima del fix il ri-centraggio era *fire-and-forget* su una notifica audio e non aspettava che il `bottomStack` avesse la sua altezza finale → per 1–2 frame la barra era visibilmente più alta.

Il commit `ac07f81` aveva già introdotto `SGRCenteredVolumeView` per tenere lo slider al centro, ma il centro veniva calcolato su `bounds` transitori e `lowerRow` non faceva `layoutIfNeeded` sul `bottomStack`. **Il risultato: ad ogni `isPaused = YES` la barra faceva un piccolo “salto” verso l’alto e poi, a volte, tornava giù dopo 50 ms.**

> Il fix in questo branch rende entrambe le operazioni **sincrone sullo stato finale del layout**: `lowerRow` fa `layoutIfNeeded` sullo stack prima di misurare, e `SGRCenteredVolumeView` aspetta che lo stack abbia 44pt e che lo slider abbia una size valida prima di toccare `frame.origin.y`, allineandosi anche allo `SGPlayerStateDidChange` (non solo alle notifiche `AVAudioSession`).

---

## 2. Dove vive la barra

```
SPTNowPlayingView
 └─ npv.bottomStackView (UIStackView verticale, 236pt + 44pt se presente)
     ├─ InformationElementsUnit   {0, 0, 402, 64}
     ├─ DurationElementUnit       {0, 64, 402, 40}  ← barra di avanzamento (SPTNowPlayingSliderV2)
     ├─ PlaybackControlsElementsUnit {0, 104, 402, 88} ← prev / play / next
     ├─ [VolumeRow]  UIStackView orizzontale 44pt  ← QUI
     │    ├─ speaker.fill (20pt)
     │    ├─ SGRCenteredVolumeView : MPVolumeView (44pt, mostra solo lo slider)
     │    └─ speaker.wave.3.fill (24pt)
     └─ FooterElementsUnit        {0, 236, 402, 44}  ← lyrics / connect / queue
```

- **File che la crea:** `tweak/Sources/Redesigned/Player/PlayerVolume.x`
  - `installVolumeRow()` cerca il `UIStackView` con `accessibilityIdentifier == "npv.bottomStackView"`, trova il `controls` (`PlaybackControlsElementsUnit`) e inserisce la riga a `controlsIndex + 1` con `insertArrangedSubview:atIndex:`.
  - La riga è un `UIStackView` orizzontale: `axis = horizontal, alignment = center, spacing = 8, layoutMargins 24pt`. Altezza vincolata `44pt`, volumeView `44pt`.
  - Le due barre colorate sono `UIImage` da 6×4pt con `capInsets` (track interna bianca 0.82 / 0.30 alpha), il thumb è trasparente 18×18 (solo area di tocco).

- **File che muove i controlli attorno alla barra:** `tweak/Sources/Redesigned/Player/PlayerFooter.x`
  - `lowerRow(row)` trasla il footer verso il basso (vicino al `safeArea`, come l’app Musica) e, *se c’è la riga volume*, sposta i controlli per centrarli tra progress e volume:
    ```objc
    CGFloat midpoint = (CGRectGetMidY(volumeRow.frame) + CGRectGetMidY(progressRow.frame)) / 2;
    controlsMove = round(midpoint - controls.center.y);
    controls.transform = CGAffineTransformMakeTranslation(0, controlsMove);
    ```
  - Prima del fix `ac07f81` il codice era `rowAbove(row)` (il view immediatamente sopra al footer). Con la riga volume in mezzo quel view non è più “controls”, quindi è stato sostituito da `controlsIn()` + `arrangedSubviewContainingVolume()`.

- **File che tiene lo slider centrato dentro `MPVolumeView`:** `SGRCenteredVolumeView` (sottoclasse di `MPVolumeView` in `PlayerVolume.x`)
  - `sgr_recenterSlider` trova lo `UISlider` più largo dentro `MPVolumeView` e fa:
    ```objc
    CGFloat centeredY = round((self.bounds.size.height - slider.frame.size.height) / 2);
    slider.frame.origin.y = centeredY;
    ```
  - Osserva `AVAudioSessionRouteChangeNotification` + `Interruption` → `sgr_scheduleRecenter` (async con doppio `dispatch` a 0 e 50 ms) e lo rifà in `layoutSubviews`.

---

## 3. Cosa succede *esattamente* quando premi Pausa

Catena di eventi (main thread):

```
1. Tap su SPTNowPlayingPlayButton → PlayButtonView uiButtonTapped (PlayerControls.x)
2.   → SPTPlayer pause:  (Core/Player)
3.   → player core → nuovo SPTPlayerState { isPaused = YES }
4.   → SGPlayerStateDidChange broadcast a tutti gli observer:
     a) PlayerArtwork.x → scaleEveryCover(YES)  → cover 1.0 → 0.84  (spring 0.6s)
     b) PlayerControls.x → refreshPlayGlyph(YES) → glyph play.fill
     c) PlayerLyrics.x → SGRPlayerLyricsWatcher: se era “alone”, setAlone(NO) → bottomStack.alpha 0→1, header alpha 0→1
     d) PlayerVinyl.x → arm verso kArmLifted, disc ferma (se vinylOn)
     e) Core → AVAudioSession disattiva l’output → posta RouteChange / Interruption (non sempre)
5. Ogni viewDidLayoutSubviews delle unit viene richiamato (il player rimisura le unit ad ogni stato):
     - PlaybackControlsElementsUnit → layOutControls() → [SGRowIn(host) layoutIfNeeded] + glyph ripozionato
       → installVolumeRow() → (se la riga non è a controls+1 la rimuove e reinserisce → stack.needsLayout = YES)
     - DurationElementUnit → layOutTimes() + watchForSeekTaps
     - FooterElementsUnit → layOutFooter() → [SGRowIn(host) layoutIfNeeded] → lowerRow(host)
     - MPVolumeView (SGRCenteredVolumeView) → layoutSubviews → sgr_recenterSlider (e async)
```

Il punto critico è **l’ordine**:

- `installVolumeRow` *inserisce* la riga ma **non fa `layoutIfNeeded` sullo stack** (lo lascia sporco).
- Subito dopo `Footer::lowerRow` fa ` [stack convertPoint:row.center …]` e poi `volumeRow.frame` / `progressRow.frame` / `controls.center`. **Se lo stack non è stato impaginato, quelle frame sono della passata precedente**: quando la riga è appena stata inserita la `volumeRow.frame` è spesso `{0,0,0,0}` o `{0,192,402,0}` (altezza 0). Allora:
  ```objc
  midpoint = (0 + 84)/2 = 42   // invece di (214+84)/2 = 149
  controlsMove = 42 - 148 = -106pt   // i controlli schizzerebbero in alto di 100pt!
  ```
  In pratica la guardia `if (volumeRow && progressRow)` non bastava e `controlsMove` diventava molto negativo → i controlli venivano traslati verso l’alto e, poiché i controlli e la volume sono adiacenti nello stack, l’utente percepiva *la volume che sale* (la barra resta a 192 ma i controlli le si avvicinano e lo spazio sopra la volume si comprime).

  Nel tree reale con altezze finali il calcolo è corretto (`midpoint ≈ 149`, `controlsMove ≈ +1pt`). La race si vede solo nel frame in cui lo stack è sporco — che coincide con il tap su pausa perché è l’unico gesto che forza un `viewDidLayoutSubviews` di tutte le unit nello stesso runloop.

- Parallelamente, **`MPVolumeView` su iOS 16–18 ricostruisce il suo `MPVolumeSlider` quando la sessione passa a “non attiva”**. Il nuovo slider viene aggiunto a `y = 0` dentro la `MPVolumeView` (alto 44pt). Finché `sgr_recenterSlider` non gira, la track è visibilmente più alta di `centeredY ≈ 10pt`. `SGRCenteredVolumeView` prima del fix osservava solo `AVAudioSessionRouteChange`/`Interruption`, che *non sempre* arrivano su un semplice `pause` (arrivano su route vera o su interruzione telefonica). Quindi lo slider restava in alto finché un successivo `layoutSubviews` casuale non lo rimetteva a posto — a volte mai, a volte dopo 50 ms con un secondo salto.

---

## 4. Root cause distillata

| Livello | Causa | Effetto visivo | File |
|---|---|---|---|
| **Layout** | `lowerRow` legge `volumeRow.frame` prima di `bottomStack.layoutIfNeeded` → frame stale/zero su pause → `controlsMove` sbagliato → controlli traslati su | controlli e volume sembrano avvicinarsi / volume “sale” | `PlayerFooter.x:179-192` |
| **Rendering MPVolumeView** | `MPVolumeView` ricrea lo slider a `y=0` su sessione inattiva; `SGRCenteredVolumeView` centra su `bounds` transitorio o non viene chiamato su pausa | track della volume a 0pt invece di ~10pt → barra più alta | `PlayerVolume.x: SGRCenteredVolumeView` |
| **Transform residuo** | Se `volumeRow` aveva un `transform` da Vinyl (`-12pt`) e poi Vinyl viene spento senza reset, resta una traslazione verso l’alto | volume permanentemente 12pt più alta | `PlayerFooter.x` + `PlayerVinyl.x` |

Tutti e tre i fattori si sommano solo sul tap di pausa perché è l’unico evento che (a) invalida la sessione audio, (b) marca lo stack come needing layout via `installVolumeRow`, (c) fa ricalcolare `lowerRow`.

---

## 5. Cosa faceva il fix precedente (`ac07f81`)

- Introdotto `SGRCenteredVolumeView` con `sgr_recenterSlider` + observer su `AVAudioSessionRouteChange`/`Interruption`.
- Rimpiazzato `rowAbove()` con `controlsIn()` / `arrangedSubviewContainingVolume()` / `arrangedSubviewContainingProgress()` per trovare i controlli anche con la riga volume in mezzo.
- Calcolo `midpoint` tra progress e volume per centrare i controlli.

Mancava:

- `layoutIfNeeded` sullo `bottomStack` prima di leggere `volumeRow.frame`.
- Guardia su `bounds.height < 10` / `slider.height < 2` prima di spostare lo slider.
- Osservazione dello stato player (`isPaused`) oltre che delle notifiche audio.
- Reset del `transform` residuo della riga volume quando Vinyl è spento.

---

## 6. Fix applicato in questo branch

### 6.1 `PlayerFooter.x` — misura solo su layout finale

```diff
 UIStackView *bottomStack = (UIStackView *)stack;
 UIView *controls = controlsIn(bottomStack, row);
 UIView *volumeRow = arrangedSubviewContainingVolume(bottomStack);
 UIView *progressRow = arrangedSubviewContainingProgress(bottomStack);
+// La riga volume è stata appena (re)inserita: lo stack è dirty.
+// Senza layoutIfNeeded le frame lette sono stale/zero e il salto su pausa è ~100pt.
+if (volumeRow && progressRow) [bottomStack layoutIfNeeded];
 CGFloat controlsMove = controls ? round(move * kControlsShare) - kControlsLift : 0;
-if (controls && volumeRow && progressRow) {
+if (controls && volumeRow && progressRow && volumeRow.bounds.size.height > 1 && progressRow.bounds.size.height > 1) {
     CGFloat midpoint = (CGRectGetMidY(volumeRow.frame) + CGRectGetMidY(progressRow.frame)) / 2;
     controlsMove = round(midpoint - controls.center.y);
 }
+// Solo Vinyl muove la riga volume; fuori da Vinyl un transform residuo fa saltare la barra su pausa.
+if (volumeRow && !CGAffineTransformIsIdentity(volumeRow.transform)) {
+    extern BOOL SGFlag(NSString *key, BOOL def);
+    if (!SGFlag(@"spotifyglass.redesign.player.vinyl", NO)) volumeRow.transform = CGAffineTransformIdentity;
+}
```

### 6.2 `PlayerVolume.x` — centraggio robusto dello slider interno

```diff
 - (void)sgr_recenterSlider {
     ...
+    if (self.bounds.size.height < 10 || slider.bounds.size.height < 2) return;
+    if (slider.bounds.size.width < 10) return;
     ...
 }

 - (void)sgr_scheduleRecenter {
+    UIStackView *stack = ... // cerca npv.bottomStackView
+    if (stack) [stack layoutIfNeeded];
     ...
 }

 - (instancetype)initWithFrame:(CGRect)frame {
     ...
+    [center addObserver:self selector:@selector(sgr_audioStateChanged:)
+                   name:@"SGPlayerStateDidChange" object:nil];
 }

+- (void)didMoveToWindow {
+    [super didMoveToWindow];
+    if (self.window) [self sgr_scheduleRecenter];
+}
+- (void)traitCollectionDidChange:(UITraitCollection *)c {
+    [super traitCollectionDidChange:c];
+    [self sgr_scheduleRecenter];
+}
```

Rationale:

- **Guard su altezze** → non centra mai dentro bounds transitori 0pt.
- **`SGPlayerStateDidChange`** → il recentering scatta *sempre* su pausa/play anche quando `AVAudioSession` non posta nulla.
- **`bottomStack layoutIfNeeded` prima di centrare** → la `MPVolumeView` ha già i suoi 44pt finali, quindi `centeredY = (44 - h)/2` è stabile.
- **`didMoveToWindow` + `traitCollectionDidChange`** → copre rotazione / `safeArea` / dark mode che prima lasciavano lo slider disallineato.

Nessun vincolo Auto Layout è stato aggiunto: il fix resta a `frame` manipulation (come prima) per non litigare con il layout interno privato di `MPVolumeView`, che su iOS 17+ usa constraint interni non esposti.

---

## 7. Come riprodurre e verificare

### 7.1 Sul telefono (manuale)

1. Impostazioni → Mod → Redesigned UI → ON, Vinyl OFF, verifica che `npv.bottomStackView` contenga la riga volume (cerca con `po` in ` lldb` o con **View Hierarchy**).
2. Apri un brano, apri il full-screen player.
3. Metti iPhone volume a ~50% (così la track è a metà).
4. Tappa **Play → Pausa → Play** 10 volte, osservando la Y della track grigia tra le due icone speaker. Con il bug la track saltava di ~10pt verso l’alto sul tap di Pausa e restava lì; con il fix resta centrata a `y ≈ 10pt` dentro i 44pt.
5. Ruota in landscape e ripeti: la track non deve tremare.
6. Con **Vinyl ON** (richiede restart), verifica che la riga volume abbia `transform = (0, -12)` e che spegnendo Vinyl e riaprendo il player la riga torni a `identity`.

### 7.2 Con l’harness (simulatore iOS)

```bash
THEOS=~/theos ./harness/player/build.sh
xcrun simctl install Booted build/PlayerHarness.app
SIMCTL_CHILD_HARNESS_SCENARIO=look xcrun simctl launch --console-pty Booted com.vojta.playerharness
# Cerca nei log:
#   redesign player: iPhone output-volume row inserted under playback controls
#   redesign player: footer row from ... to ... , controls lift 1
# senza "WRONG" o salti di 100pt
HARNESS_SCENARIO=taps xcrun simctl launch --console-pty Booted com.vojta.playerharness
# atteso: tap checks: 25 of 25 right -- PASS  (il tap sulla volume non deve fare seek)
```

Per vedere il salto prima del fix, ricompila l’harness contro il commit precedente:

```bash
SRC=~/spoti.pw-before-fix OUT=/tmp/harness-old ./harness/player/build.sh
```

e confronta i video:

```bash
xcrun simctl io Booted recordVideo -f run.mp4   # tappa pausa durante la registrazione
ffmpeg -ss 2 -t 3 -i run.mp4 -vf "fps=10,scale=180:-1,tile=10x1" strip.png
```

### 7.3 Log attesi dopo il fix

```
redesign player: iPhone output-volume row inserted under playback controls
redesign player: footer row from 495 to 515 of 874 (safe area 34), controls lift 1
redesign player: play glyph over _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit ...
```

Nessun secondo log di `footer row ... controls lift -106` (quello del bug).

---

## 8. Casi limite e note

- **Spotify Free (`ReinventFree`)**: il player usa classi diverse (`ReinventFreePlaybackControlsElementsUnit`, `ReinventFreeFooterElementUnit`) → entrambi hookati, stesso fix. Verificato in `PlayerFooter.x` + `PlayerVolume.x` che hookano entrambe le classi.
- **Lyrics “alone”**: quando le linee vanno a tutto schermo (`setAlone(YES)`) il `bottomStack` va a `alpha 0`. `lowerRow` non gira perché `row.alpha < 0.01` è filtrato in `SGRFooterReach.hitTest`, ma la volume resta comunque a `alpha 0` con il resto dello stack → nessun salto.
- **Vinyl mode**: muove *intenzionalmente* volume di `-12pt` e progress di `+12pt` (`PlayerVinyl.x:updateVinylPlaybackSpacing`). Il fix non tocca quel codice: il reset a `identity` scatta solo quando `SGFlag(vinyl) == NO`.
- **iOS 26 UISlider “thumb has settled”**: il harness gestisce il rilascio ritardato (`whenSettled`), ma non influisce sulla volume perché `SGRSeekTapWatcher` è installato solo sullo `UISlider` del progress (`SPTNowPlayingSliderV2`), mai sulla volume.

---

## 9. Cosa resta da fare (opzionale)

- Sostituire il `frame.origin.y` manipulation con un vincolo `centerY` interno alla `MPVolumeView` se Apple lo rende stabile su iOS 18+ (oggi è fragile perché la gerarchia interna di `MPVolumeView` è privata e cambia ogni major).
- Aggiungere uno unit test harness `HARNESS_SCENARIO=volume` che tappa pausa 20 volte e asserisce `CGRectGetMidY(volumeRow.frame)` stabile entro ±0.5pt.
- Loggare `midpoint` e `controlsMove` su ogni `lowerRow` (oggi solo al primo `dispatch_once`) per diagnosticare regressioni future senza ricompilare.

---

## 10. File toccati

- `tweak/Sources/Redesigned/Player/PlayerVolume.x` — `SGRCenteredVolumeView` robusto
- `tweak/Sources/Redesigned/Player/PlayerFooter.x` — `lowerRow` misura solo dopo `layoutIfNeeded`, guarda altezze, reset transform residuo

Nessun altro file è stato modificato per questo bug.

---

*Se vuoi che prepari anche la PR su `beta` con questi due diff e uno screenshot “prima/dopo”, dimmelo e la apro dal branch `arena/78af061e-spoti-pw`.*
