# Zjednodušení projektu Winston 8 října 2026

Winston má užitečně oddělené čtení katalogu, změny dat a transakce se soubory. Největší bezpečný prostor pro zjednodušení představovaly opakované postupy uvnitř těchto vrstev. Úpravy sjednocují zpracování obálek, stránkování, párování vydání, zápisy do katalogu a výpočty kontrolních součtů.

Produkční Swift kód v adresáři `Winston/` se zkrátil z **87 723 na 87 521 řádků**, tedy o **202 řádků**. Změnilo se 10 produkčních souborů a 3 testovací soubory; testy mají navíc 143 řádků. Počet produkčních souborů zůstal 228. Nevznikla nová závislost ani změna databázového schématu.

Porovnání vychází ze stavu pracovního stromu na začátku tohoto rozboru. Dřívější necommitované úpravy byly zachovány; porovnání jejich Swift souborů před prací a po ní neukázalo žádný rozdíl. Celkový `git diff` zahrnuje také tuto předchozí práci.

## Provedené změny

### Jedna cesta pro uložení obálky

[CoverService.swift](../Winston/Features/Library/Services/CoverService.swift) opakoval přípravu transakce, ověřování aktuálnosti a commit zvlášť pro vlastní obálku a obnovení původní. Společný postup nyní vlastní `applyCover`.

Aktuálnost se stále kontroluje před přípravou souborů, po čekání na přípravu a uvnitř zápisu do katalogu. Zastaralá připravená transakce se zruší. Neplatný vlastní obrázek původní obálku zachová; obnovení bez nalezené obálky odstraní vlastní obrázek, stejně jako před úpravou.

Pracovní úloha dříve vracela současně `NSImage` a JPEG data, přestože následující kód obrázek nepoužíval. Nyní vrací pouze `Data`. Odpadlo držení nepoužívaného obrázku v návratové hodnotě i obal označený `@unchecked Sendable`. Metody vracejí volitelný handle úlohy, takže testy mohou čekat na skutečné dokončení bez odhadovaných prodlev; dosavadní volající mohou výsledek dál ignorovat.

### Společné stránkování knih

[LibrarySupport.swift](../Winston/Features/Library/Services/LibrarySupport.swift) obsahuje `BookPageCursor`, který společně používají [párování vydání](../Winston/Features/Library/Services/EditionService.swift) a [import historie čtení](../Winston/Core/Persistence/ReadingHistoryImport.swift).

Na jednom místě se vytváří dotaz seřazený podle data přidání a UUID i posun přes knihy se stejným hraničním datem. Každý čteč dál načítá vlastní potřebné vztahy a převádí modely na hodnoty na svém executorovi. Sdílení nepřidává další načítání celé knihovny ani nepřenáší živé SwiftData modely mezi actory. Jde o zachování dosavadního algoritmu, nikoli tvrzení o rychlejším stránkování.

### Společná příprava a vyhodnocení kandidátů

[EditionService.swift](../Winston/Features/Library/Services/EditionService.swift) měl dvě totožné konstrukce `EditionCandidate`. Současná konstrukce zachovává všechna vstupní pole, obsahové hashe všech souborů, velikost primárního souboru i odvozenou identitu díla.

Vyhodnocení jedné knihy nyní používá existující dávkovou cestu. Dávková cesta znovu využívá `evaluateAndLog`, místo aby opakovala sběr výsledků a statistik. Obnovování indexu, zneplatnění starých návrhů a pravidla automatického seskupování zůstávají stejné.

### Společný zápis do katalogu

[CatalogMutationService.swift](../Winston/Features/Library/Services/CatalogMutationService.swift) nyní vede připravené dávky i obě varianty souborových transakcí přes existující `commit`. Oprava invariantů, synchronní uložení a zveřejnění změny mají jednu implementaci.

Souborové obálky dál vlastní přípravu, identifikátor operace, zrušení transakcí při neúspěchu a dokončení publikace souborů po uložení databáze. Zůstává zachovaný rozdíl mezi selháním uložení a soubory čekajícími na obnovu. Kontrola zrušení dávky zůstává na původním místě před commitem.

### Opětovné využití výpočtu kontrolního součtu

[StoreRecoveryCoordinator.swift](../Winston/Core/Persistence/StoreRecoveryCoordinator.swift) a [LibrarySnapshotCoordinator.swift](../Winston/Core/Persistence/LibrarySnapshotCoordinator.swift) používají existující `ContentHasher.sha256(of:)`. Odpadly dvě kopie čtení souboru po blocích a jeden import `CryptoKit`.

Velikost bloku zůstává 1 MiB, formát SHA-256 je stejný a výpočet v těchto dvou cestách nadále nepřidává kontrolu zrušení. Kontrola běžného souboru a odmítnutí symlinků při vytváření snapshotu zůstaly před výpočtem hashe.

### Menší opakování a nepoužívané deklarace

[Book.swift](../Winston/Core/Models/Book.swift) sdílí jeden soukromý pomocník pro doplnění prázdných textových metadat při lokálním i online načítání. Pravidla pro autory, tagy a aktualizaci komunitního hodnocení zůstávají původní.

Odstraněny byly nepoužívané `LibraryQuery.displayMatches` a `CalibreLibraryReader.metadataDBName`. Kontrola použití zahrnovala produkční kód i testy. Metody volané přes systémové protokoly, například `SerialExecutor.enqueue`, se za nepoužívané nepovažovaly.

## Posouzení hlavních částí projektu

| Oblast | Závěr rozboru |
| --- | --- |
| Závislosti | Projekt používá jeden Swift balíček ZIPFoundation a knihovny libmtp/libusb. Zajišťují skutečné funkce EPUB a komunikace s Kindle. Jejich odstranění by vyžadovalo náhradní implementaci. |
| Datový model | `Work`, `Book` a `BookAsset` mají odlišný význam a životní cyklus. Snapshoty kopírují hodnoty kvůli bezpečnému porovnávání a obnově. Podobné seznamy polí nejsou důvod ke sloučení těchto modelů. |
| Čtení knihovny | `LibraryProjectionStore` a `LibraryReadModel` oddělují SwiftData od odvozených výsledků a umožňují aktualizace podle změněných UUID. Nahrazení jedním širokým dotazem v kořenovém view by odstranilo tuto kontrolu. |
| Import | `ImportService` má 2 203 řádků a koordinuje přípravu, analýzu, párování, dávkové uložení i obnovu. Vlastnictví zdrojů a transakce chrání částečně dokončenou práci. U dalších úprav dává smysl přesouvat konkrétní společný postup k existujícímu vlastníkovi. |
| Převody a zařízení | Nativní převod už sdílí otevřený EPUB archiv. MTP a připojený disk potřebují různé transporty; společnou nadřazenou cestou je `TransferQueue`. Formát MOBI a odlišné chování odpojení zařízení nejsou vhodným cílem plošného zkracování. |
| Síťové služby | `HardcoverAPIClient` a `OPDSRequestPolicy` již soustřeďují sdílenou komunikaci a pravidla přístupu. Cache a rušení požadavků mají význam podle konkrétní služby. Další obecná síťová vrstva zde není pro tento úklid potřeba. |
| Pluginy | Samostatné pracovní procesy, oprávnění, časové limity a vazba souhlasu na obsah pluginu mají vlastní účel. Přesun do procesu aplikace by změnil izolaci. |
| Rozhraní | Projekt má společné komponenty pro obálky, stavové zprávy, operace a panely akcí. Témata mají záměrně různé chování a texty. Tento průchod zachovává strukturu obrazovek a uživatelské ovládání. |

Statický průchod hledal deklarace bez použití a opakované bloky napříč 228 soubory; podrobná kontrola následovala u společných datových a transakčních cest. Textová shoda sama o sobě nestačila k odstranění kódu. Například doplňování metadat při slučování vydání považuje bílé znaky za prázdnou hodnotu, zatímco `Book.apply` zachovává již neprázdný text. Tyto dvě politiky zůstaly oddělené.

Podobně kopírování souboru s průběžným hashováním zůstává jediným průchodem nad daty. Nahrazení samostatným kopírováním a následným voláním společného hasheru by přidalo další čtení celého souboru.

## Ověření

Prostředí: macOS 27.2, arm64, Xcode 27.0 (`27A266a`), Swift 6.4. Testy používají izolované dočasné knihovny.

| Běh celé sady WinstonTests | Úspěšné testy | Selhání | Vypnuté testy |
| --- | ---: | ---: | ---: |
| Výchozí Debug před úpravami | 998 | 0 | 2 |
| Konečný Debug | 1 004 | 0 | 2 |
| Konečný Release s optimalizací celého modulu | 1 004 | 0 | 2 |

Počty pocházejí z hlavního souhrnu `xcresulttool`; parametrizované případy mají navíc samostatná spuštění. Vypnuté testy jsou existující volitelné benchmarky.

Release používá projektovou optimalizaci `-O`, režim `wholemodule` a `ENABLE_TESTABILITY=YES`. Konečné sestavení vykázalo nula chyb a nula varování; souhrny obou konečných testovacích běhů mají prázdné `testFailures` i `runtimeWarnings`.

První přímý Release běh skončil před spuštěním testů: zavaděč odmítl podpis přibalené `libmtp.9.dylib`. Následné ověření použilo existující postup projektu: sestavit pro testy, podepsat lokální produkt pomocí `Scripts/LibraryPerformance.entitlements` a spustit `test-without-building`. Tento podpis se týká pouze testovacího produktu v `build/DeepAuditReleaseDD`; projektová a distribuční nastavení se neměnila.

Šest nových testů pokrývá vlastní obálku z dat i URL, neplatný obrázek, obnovení s nalezenou obálkou i bez ní, zrušení a nahrazení čekající operace, změnu knihy během analýzy a selhání uložení včetně úklidu transakce. Tyto testy prošly před sjednocením zpracování obálek i po něm. Dva existující testy stránkování nově zkoušejí také přechody mezi skupinami dat; 257 knih se načte po 32 bez ztrát a opakování.

Prošly také `Scripts/check-release-readiness.sh`, `ruby Scripts/audit-catalog-write-awaits.rb .` a `git diff --check`. Audit zápisů je pomocná statická kontrola, nikoli náhrada transakčních testů.

Výsledkové balíčky jsou v `/private/tmp/WinstonSimplification-20261008/`: `baseline-run.xcresult`, `cover-contracts.xcresult`, `cover-refactored.xcresult`, `paging-verified.xcresult`, `complete-debug.xcresult`, `complete-release-build.xcresult` a `complete-release.xcresult`.

Reprodukce úplné regrese:

```sh
xcodebuild test -workspace Winston.xcworkspace -scheme Winston \
  -destination 'platform=macOS' -derivedDataPath build/DeepAuditDD \
  -only-testing:WinstonTests

xcodebuild build-for-testing -workspace Winston.xcworkspace -scheme Winston \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DeepAuditReleaseDD ENABLE_TESTABILITY=YES

codesign --force --deep --sign - \
  --entitlements Scripts/LibraryPerformance.entitlements \
  build/DeepAuditReleaseDD/Build/Products/Release/Winston.app

xcodebuild test-without-building -workspace Winston.xcworkspace -scheme Winston \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DeepAuditReleaseDD -only-testing:WinstonTests
```

## Dopad a hranice výsledku

Zjednodušení snižuje počet míst, která se musí při změně pravidel upravit společně. U obálek navíc odstraňuje přenos a držení nepoužívaného dekódovaného obrázku. Velikost instalačního balíčku, špičková paměť a rychlost procházení nebyly měřeny; počet odstraněných řádků není měřítkem těchto vlastností.

Pro další výkonovou práci mají nejvyšší hodnotu měření spuštění knihovny a procházení skutečných obálek na stejných datech a v Release konfiguraci. Předchozí výkonnostní audity obsahují užitečné scénáře, jejich starší naměřené časy však nepopisují tento stav projektu. V tomto průchodu se neprováděl ruční UI ani hardwarový test na fyzické čtečce.
