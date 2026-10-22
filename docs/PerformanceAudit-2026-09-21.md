# Výkon a kvalita kódu — audit 21. září 2026

## Rozsah a stav

Audit vychází z aktuálního pracovního stromu nad `46f8782`. Zaměřuje se na knihovnu a její projekci, fulltextový index, obálky, síťové katalogy, rušení operací a nastavení. Není to tvrzení, že všechny funkce aplikace nebo všechna zařízení prošly kompletním ověřením.

**Funkční regrese prošla v Debug i v optimalizovaném Release s WMO. Předběžné UI srovnání změřilo pouze mřížku se zástupnými obálkami a v obou variantách zaznamenalo výrazné záseky.** Kontrola skutečně zobrazeného JPEG následně selhala už před scrollováním. Měření s načtenými obálkami ani ověření přínosu změny materiálového pozadí nejsou dokončené.

Při zahájení už byly rozpracované změny v `ContentView.swift`, `UITestScenarioView.swift`, `WinstonUITests.swift` a necommitnutý audit ze 6. září. Zůstaly zachované. Staré časy a počty testů nejsou výsledky dnešního kódu.

Pracovní seznam:

- [x] Prověřit aktuální implementaci a odlišit staré výsledky od současných důkazů.
- [x] Opravit vyhledávání sekcí jedné knihy v plnotextovém indexu.
- [x] Omezit diskovou cache odvozených obálek a zachovat zobrazení při selhání zápisu.
- [x] Opravit oddělení preferencí a trvalé cachování síťových neúspěchů.
- [x] Ověřit síťové rušení a souběh operací v cílených kontrolách i celé jednotkové sadě.
- [x] Sestavit aplikaci a spustit celou jednotkovou sadu v Xcode (Debug).
- [x] Ověřit kompletní jednotkovou sadu také v Release s WMO.
- [x] Změřit metadata/index na 1 000, 10 000 a 50 000 připravených záznamech; oddělit tento výsledek od výkonu aplikace.
- [x] Provést předběžné Release A/B mřížky při pevné geometrii; zjistit, že oba běhy zobrazovaly zástupné obálky.
- [ ] Vyřešit zobrazení fixture JPEG a zopakovat měření mřížky s načtenými obálkami; zaznamenat záseky, paměť a hlavní vlákno.

## Potvrzené nálezy a změny

| Priorita | Nález | Oprava a její hranice |
| --- | --- | --- |
| Vysoká | `FullTextIndex` používal `WHERE book_id = ?` nad FTS5 sloupcem `UNINDEXED`. Přidání, nahrazení a odebrání jedné knihy tak procházelo sekce celého indexu; opakovaná synchronizace také zapisovala nezměněný dokument. | Schéma v3 přidává běžný index knihy → rowid sekcí, upravuje jen příslušné řádky a skutečně nezměněné dokumenty nezapisuje. Migrace v2 zachovává text a je transakční. Hashování zdroje nově používá existující cancellable variantu s kontrolou zrušení mezi 1MiB bloky. |
| Střední | Odvozené obálky v `Application Support/Winston/DerivedCovers` rostly bez omezení. | Výchozí rozpočet 256 MiB komprimovaných souborů a 20 000 položek. Jednorázová inventura, následné přírůstkové účtování, promazání nejdéle nepoužitých položek s rezervou 10 %. Souborové recency údaje se aktualizují nejvýše jednou za minutu na položku. |
| Střední | Úspěšně dekódovaná obálka se nezobrazila, když nešel zapsat její odvozený náhled. | Zápis do diskové cache je volitelný; připravený obrázek se vrací i při odmítnutí či selhání zápisu. |
| Střední | `AppSettings(defaults:)` respektovalo předané preference pouze u katalogů. Ostatní inicializace, změny a migrace tokenu používaly globální `UserDefaults.standard`. | Všechna nastavení používají stejné předané úložiště. Výchozí produkční doména zůstává `.standard`. Testy ani další izolované instance nepřepisují jinou doménu přes tuto třídu. |
| Střední | `DiscoveryImageLoader` cachoval `nil` po neúspěchu stejně jako obrázek a odmítal platné obrázky menší než 1 001 bajtů. | Cachují se jen dekódované obrázky; další požadavek po chybě může uspět. Platnost malého souboru posuzuje dekodér. |
| Střední | OPDS feed při předčasném ukončení kvůli limitu nechával běžet underlying přenos a některá zrušení klasifikoval jako síťovou chybu. | Opuštění čtení explicitně ruší datovou úlohu. Zrušení se propaguje jako `CancellationError`. |
| Vysoká | Po „Zrušit → stáhnout znovu“ mohla pozdní obsluha první úlohy smazat stav i handle nového stahování nebo zobrazit starou chybu. | Stahování má vlastní identitu generace. Úklid, chyba i callback importu mění stav pouze při shodě aktuální generace. Již předaný import si zachovává svého vlastníka; zrušení stahování nevydáváme za rollback importu. |
| Kandidát na výkonový přínos | Každá karta mřížky obsahovala `ultraThinMaterial` i druhé tónované pozadí, v rozporu s pravidly projektu pro obsahové karty. | Jedno neprůsvitné pozadí ze stávajícího motivu. Zůstává stávající focus a výběrový rámeček. Je odstraněna konkrétní renderovací vrstva; jedno předběžné A/B se zástupnými obálkami nepotvrzuje příčinu rozdílu ani vyřešení záseků. |
| Opravená překážka sestavení | Swift 6.4 při WMO kompilaci celé testovací sady nesprávně přiřadil `nonisolated` actoru `FakeKindleConnection` a odmítl jeho inicializaci. | Konformance protokolu je v samostatném extension; stav, metody a inicializace jsou stejné. Přesný původní frontend krok selhal, varianta se samostatnou konformancí prošla bez diagnostiky. Následně prošel celý Release build i testy se zachovaným WMO. |

Diskový limit není absolutním limitem fyzické spotřeby disku: nezahrnuje alokační režii souborového systému ani originální obálky či osiřelé skryté dočasné soubory `.tmp`. Selhání mazání se nevydává za uvolněné místo. Úklid rozpoznává pouze názvy odvozených JPEG náhledů a vynechává symlinky, cizí soubory a adresáře. Rozpočet spravuje sdílený produkční actor s jednorázovou inventurou; nejde o koordinovaný limit pro více procesů či nezávislých instancí zapisujících do stejné složky. Test souběžného zápisu ověřuje atomické zveřejnění náhledu, nikoli sdílené účtování rozpočtu.

Zjednodušení kódu je konkrétní: odstranění opakovaného zápisu identického dokumentu, nepoužitelné cache neúspěchů, větvení zobrazení podle výsledku volitelného diskového zápisu a dvojího vlastnictví preferencí. Nová kontrola diskového rozpočtu i regresní testy přidávají potřebný kód; pokles celkového počtu řádků není cílem ani výsledkem tohoto auditu.

## Aktuální ověření

Stroj: Apple M4 Pro, 48 GiB RAM, macOS 27.0 (`26A428`), Xcode 27.0 (`27A266a`), Swift 6.4. Při zahájení byly dostupné pouze Command Line Tools; po reinstalaci Xcode proběhlo ověření přímo z workspace. Release používá projektové `-O` a `wholemodule`, `ENABLE_TESTABILITY=YES` a `WINSTON_UI_TESTING` pro zpřístupnění izolované UI fixture. Optimalizace se kvůli chybě kompilátoru nevypínala.

| Sada `WinstonTests` | Úspěšné testy | Selhání | Vypnuté testy | Čas vykázaný Swift Testing |
| --- | ---: | ---: | ---: | ---: |
| Debug | 998 | 0 | 2 | 53,544 s |
| Release, WMO | 999 | 0 | 1 | 48,737 s |

Počty vycházejí z hlavního souhrnu `xcresulttool`; parametrizované případy mají navíc vlastní počty jednotlivých spuštění. Swift Testing v obou bězích uvádí 1 000 testů ve 113 sadách včetně vypnutých. V Debug byly vypnuté oba opt-in benchmarky; v Release byl zapnutý benchmark metadat, zatímco corpus benchmark zůstal vypnutý. Oba souhrny mají prázdné `testFailures` i `runtimeWarnings`. Časy tabulky nezahrnují celý build a přípravu runneru.

Úplný Release běh předcházel pozdějšímu doplnění pixelových UI asercí a dočasnému trasování úlohy obálky. Je dokladem jednotkové regrese uvedené sestavy, nikoli vyřešení následně nalezeného problému se zobrazením obálek.

Důkazy:

- Debug: `/private/tmp/WinstonDeepAuditDebug-Retry-20260921.xcresult` a `/private/tmp/WinstonDeepAuditDebug-Retry-20260921-summary.json`.
- Release: `/private/tmp/WinstonDeepAuditRelease-Final-20260921.xcresult`, souhrn `/private/tmp/WinstonDeepAuditRelease-Final-20260921-summary.json` a log `/private/tmp/WinstonDeepAuditRelease-Final-20260921.log`. Build skončil `TEST BUILD SUCCEEDED` v `/private/tmp/WinstonDeepAuditReleaseBuild-Final-20260921.log`; běh skončil `TEST EXECUTE SUCCEEDED`.
- Oprava testovacího actoru: `/private/tmp/WinstonActorInitAudit-20260921/results.txt`. Přesný původně selhávající WMO frontend krok po oddělení konformance vytvořil 79 objektových souborů bez diagnostiky. Změněný helper a jeho volající se zvlášť zkompilovali také v Debug. Úplný Debug běh předcházel této poslední změně helperu; úplný Release běh už ji zahrnuje.
- `Scripts/check-release-readiness.sh` prošel; `ruby Scripts/audit-catalog-write-awaits.rb .` nenašel kandidáty; `git diff --check` prošel při průběžné kontrole.

Celá sada zahrnuje skutečné ebook parsery, SwiftData a nové regrese cache, nastavení, migrace indexu a síťového rušení. Není to UI měření ani zkouška na skutečné uživatelově knihovně či fyzické čtečce. Repo test okamžitého opakování stahování používá i krátký interval pro doběhnutí catch; samotný interval není deterministickou bariérou. Další izolované kontroly opožděné chyby, zrušení a callbacku starého importu čekaly na skutečné task handles.

Před dostupností Xcode prošly také izolované kontroly nad produkčním kódem: šest testů diskové cache, deset testů nastavení v Debug i Release, pět fulltextových kontrol, tři síťové kontroly a tři kontroly vlastnictví stahování. Jejich omezené adaptéry nenahrazují následnou plnou regresi. Podklady zůstávají v `/private/tmp/WinstonDerivedCoverAudit-20260921`, `/private/tmp/WinstonSettingsAudit-20260921`, `/private/tmp/WinstonFullTextAudit-20260921` a `/private/tmp/winston-services-audit`; kvůli nim nevznikla alternativní produkční implementace.

### Optimalizovaný index metadat

Výsledky pocházejí z `LibraryReadModelTests.immutableIndexedQueryScalingBenchmark` v uvedeném úplném Release běhu. Pro každou velikost proběhlo jedno měření uvnitř celé testovací sady; nejde o medián ani p95. Příprava immutable záznamů proběhla mimo měřený interval. Dataset obsahuje různé názvy, 250 autorů a 1 % rozečtených knih. Každý dotaz kontroluje celé pořadí proti referenčnímu výpočtu a očekávaný počet výsledků.

| Operace | 1 000 knih | 10 000 knih | 50 000 knih |
| --- | ---: | ---: | ---: |
| Sestavení indexu | 4,06 ms | 40,50 ms | 230,40 ms |
| Všechny knihy, zdrojové pořadí | 0,52 ms | 6,43 ms | 34,75 ms |
| Tag + autor + formát, všechny knihy | 0,89 ms | 10,01 ms | 51,28 ms |
| Textové hledání + řazení názvu, všechny knihy | 4,87 ms | 46,50 ms | 263,16 ms |
| Rozečtené, 10 / 100 / 500 výsledků | 0,05 ms | 0,51 ms | 2,66 ms |
| Dávkové odstranění 1 000 záznamů | 4,70 ms | 6,74 ms | 9,40 ms |

Zdrojové časy jsou řádky `PERF immutable` v Release logu. Měří práci nad připravenými metadaty, nikoli počáteční SwiftData fetch, čtení ebooků, vykreslení nebo odezvu celé aplikace. Přibližně 263 ms pro široký řazený dotaz na 50 000 knihách zůstává příležitostí ke zlepšení. Procentuální porovnání se zářijovým starším auditem by nebylo platné bez stejného toolchainu a podmínek.

### Mřížka: předběžné A/B pouze se zástupnými obálkami

Pro srovnání vznikla kopie `/private/tmp/WinstonGridBaseline-20260921`; při přípravě kontrola SHA-256 ověřila, že jedinou odlišností je `Effects.swift` z původního HEAD s materiálovým pozadím. Ověření je v `/private/tmp/WinstonGridBaseline-20260921-verification.json`. Optimalizované app bundly a odpovídající dSYM jsou zachované v `/private/tmp/WinstonGridWMO-20260921/{baseline,current}`. Obě varianty používají společný UI runner a vlastní soubory `baseline.xctestrun` a `current.xctestrun`. Dočasné měřicí bundly mají podpis s existujícími performance entitlements; distribuovaná aplikace se tím neměnila.

První baseline pokus nespustil test kvůli zrušenému ověření totožnosti macOS (`com.apple.LocalAuthentication Code=-2`, `/private/tmp/WinstonGridBaseline-20260921.log`). Po udělení souhlasu proběhly úspěšně baseline `/private/tmp/WinstonGridBaseline-Retry-20260921.xcresult` i současná varianta `/private/tmp/WinstonGridCurrent-20260921.xcresult`. **Oba exportované snímky však obsahují barevné zástupné obálky místo jednolitých šedých JPEG z fixture.** Původní aserce ověřovaly výběr a návrat knihy na obrazovku, nikoli skutečné zobrazení obrázku.

Následují průměry dvou iterací z jedné dvojice běhů; nejde o opakované či střídavé A/B ani o výsledek pro načtené JPEG:

| Metrika při zástupných obálkách | Původní materiál | Neprůsvitné pozadí |
| --- | ---: | ---: |
| Poměr trvání záseků | 411,520 ms/s | 347,769 ms/s |
| Celkové trvání záseků | 9,7625 s | 7,70417 s |
| Počet záseků | 248 | 245,5 |
| Čas měřené scrollovací smyčky | 23,1922 s | 21,5764 s |
| Špičková fyzická paměť | 324 445 kB | 329 295 kB |

Zdrojové CSV jsou v `/private/tmp/WinstonGridBaseline-Retry-20260921-metrics` a `/private/tmp/WinstonGridCurrent-20260921-metrics`; kB ponecháváme v jednotce exportu. Záseky zůstávají závažné v obou variantách. Rozdíl jedné dvojice běhů nelze spolehlivě připsat odstranění materiálu a vyšší špičková paměť současné varianty nedokládá zlepšení paměti. Čas scrollovací smyčky není FPS. Cíl plynulého procházení knihovny tím není splněn.

Test kontroluje okno 1 280 × 800, kompaktní šířku karet, výběr, šipky a mezerník, skutečné odscrollování první knihy i její návrat. Fixture používá 1 000 papírových knih v in-memory katalogu a uložené JPEG 800 × 1 200 pixelů. Nově doplněné pixelové aserce kontrolují skutečnou šedou obálku před měřením i po návratu. První pokus s nimi neměl dostupné okno; opakování `/private/tmp/WinstonGridCoverAssertion-Retry-20260921.xcresult` už **selhalo na počáteční aserci JPEG před scrollováním**. Video potvrzuje počáteční zástupné obálky, takže nejde jen o chybějící obnovu po návratu do mřížky.

Při izolované diagnostice existovalo všech 1 000 JPEG a přesný produkční `ImageTranscoder` úspěšně dekódoval první soubor na 400 × 600 pixelů (`/private/tmp/WinstonCoverDecoderDiagnostic-20260921.swift`). Fixture i zobrazení používají stejný edition UUID; načtení uložené obálky předchází kontrole zdrojového ebooku. Dočasné trasování první obálky dále vykázalo správnou existující cestu, neprázdný výsledek resolveru a nezrušenou úlohu. To zatím nedokládá správné vykreslení ani určení příčiny; produkční oprava zobrazení ještě není potvrzena. Dočasné trasování není součástí zamýšlené finální změny.

Dosavadní UI měření neověřuje persistentní cold-start, extrakci obálek z ebooků ani diskový rozpočet odvozených náhledů. Profil hlavního vlákna dosud chybí. Příkazy pro připojení Time Profileru ke správnému XCTest procesu a rozbor zásobníků jsou připravené v `/private/tmp/WinstonGridProfileTools-20260921/README.md`; samotná příprava pomocných skriptů není profilováním. Diagnostický běh s profilerem se musí oddělit od neprofilovaného A/B měření.

### Ověření složitosti SQL

Přesné původní a nové SQL dotazy byly spuštěny v SQLite 3.53.4 s počítáním kroků virtuálního stroje. Každá existující kniha má 10 sekcí. Měřen je samotný DELETE z FTS tabulky; následný DELETE z pomocné mapy a režie transakce v číslech nejsou. Jde o práci SQL operace, nikoliv FPS nebo čas celé synchronizace aplikace.

| Celkem sekcí | Původní DELETE neexistující knihy | Nový DELETE neexistující knihy | Původní DELETE existující knihy | Nový DELETE existující knihy |
| --- | ---: | ---: | ---: | ---: |
| 100 | 1 033 | 32 | 1 409 | 641 |
| 1 000 | 10 033 | 32 | 10 409 | 641 |
| 10 000 | 100 033 | 32 | 100 409 | 641 |

`EXPLAIN QUERY PLAN` potvrzuje použití covering indexu `section_rows_book_id` a přístupu k FTS rowid oproti původnímu úplnému průchodu. Výsledek je reprodukovatelný pomocí `/private/tmp/WinstonFullTextAudit-20260921/sql-scaling.py`; log je vedle něj. Verze SQLite je verze tohoto měřicího procesu, nikoliv tvrzení o SQLite linkovaném do aplikace.

## Další příležitosti podle dopadu

1. **Zobrazení obálek a skutečný profil mřížky v Release.** Nejprve vyřešit selhání počáteční pixelové aserce fixture JPEG. Potom zopakovat měření se skutečně načtenými obálkami při stejném okně 1 280 × 800, kompaktním zoomu a stejném datasetu před/po změně. Předběžné měření se zástupnými obálkami už potvrzuje výrazné záseky v obou současných Release variantách, ale ne jejich příčinu. Profilovat hlavní vlákno, cold/warm obálky, scrolling oběma směry a ustálení paměti; zachovat kontrolu výběru, šipek, mezerníku a focusu.
2. **Počáteční databázová projekce.** `LibraryProjectionStore.rebuild` stále synchronně načítá celý katalog a prefetchuje assets, collections, highlights i work. Pozdější kooperativní zachytávání snapshotů po zhruba 4 ms neomezuje dobu tohoto fetch. Pro velké persistentní knihovny je potřeba změřit SQL/faulting a oddělit lehkou projekci seznamu od vztahů detailu. Pouhé `fetchLimit` by rozbilo úplnost filtrů a počtů; tato změna vyžaduje společný návrh dotazů a sidebaru.
3. **Rušení vzdálených obálek a rozpočet souběhu.** Sdílení rozpracované úlohy v Discovery stále nemá počítání aktivních zájemců. Opuštění jedné buňky nesmí rušit obrázek potřebný jinou; případné omezení musí omezit zbytečný přenos bez rozbití deduplikace. Nejprve změřit rychlé scrollování na pomalé síti.
4. **Měřené regresní limity.** Stanovit baseline na stabilním toolchainu a stejném datasetu, oddělit metadata/index od SwiftData načtení, vykreslení a skutečného parsování knih. Přidat opakované průchody a současný import/údržbu. Čas XCTest scrollovací smyčky není FPS.

## Primární podklady

Způsob výběru UI optimalizací vychází z oddělení dlouhých aktualizací a nadbytečných invalidací v [Apple: Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance) a [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/). Plynulost se proto nepotvrzuje samotným zjednodušením zdrojového kódu.

FTS5 má implicitní celočíselné `rowid`, zatímco `UNINDEXED` nezahrnuje obsah daného sloupce do fulltextového indexu. Návrh využívá běžný index pro identitu knihy a `rowid` pro práci se sekcemi; viz [SQLite FTS5](https://www.sqlite.org/fts5.html). Síťová oprava pracuje s úlohou dostupnou na [URLSession.AsyncBytes](https://developer.apple.com/documentation/foundation/urlsession/asyncbytes).

Návrhový kontext této úpravy tvoří existující motivy a pravidla `CLAUDE.md`. Pro budoucí samostatnou práci na designu lze tento kontext zachytit pomocí `$impeccable init`; není to podmínka nynějšího auditu.
