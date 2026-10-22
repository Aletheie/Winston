# Audit výkonu knihovny — 6.–7. září 2026

Audit se zaměřuje na procházení knih, obálky, vyhledávání, aktualizace katalogu a souběžnou údržbu. Zahrnuje implementované opravy, refaktor společných cest a regresní testy. Výchozí pracovní strom obsahoval rozsáhlé necommitované změny; byly zachovány. Celkový `git diff` proto není měřítkem změn provedených jen během tohoto auditu.

## Prostředí a interpretace

Ověřovací stroj: MacBook Pro, Apple M4 Pro, 48 GiB RAM, macOS 27.0 (26A5416b), Xcode 27.0 beta (27A5237l), arm64. Optimalizované testy používají konfiguraci Release s `ENABLE_TESTABILITY=YES`. Testování probíhá v izolovaných katalozích a dočasných adresářích.

Beta kompilátor selhal při WMO kompilaci testovacího actoru `FakeKindleConnection` s neodpovídající diagnostikou `nonisolated`. Pro měřicí běh byla použita optimalizace `-O` s příkazovým `SWIFT_COMPILATION_MODE=singlefile`; projektová nastavení zůstala zachována. Ad hoc Release testovací produkt byl podepsán existujícími `Scripts/LibraryPerformance.entitlements`, stejně jako produkt určený pro Instruments, aby šlo načíst přibalené Homebrew knihovny. Tento podpis patří výhradně dočasnému měřicímu produktu.

Velikost souborů knih a počet záznamů jsou dvě různé veličiny. Procházení nemá číst celý obsah ebooků. Metadata, vyhledávací indexy a počáteční načtení však stále rostou s počtem knih, vydání, souborů, kolekcí a zvýraznění. Výkon na libovolném objemu dat a absolutně nulové záseky nelze z konečného měření garantovat.

## Nálezy a implementované změny

| Priorita | Problém a dopad | Oprava |
| --- | --- | --- |
| Vysoká | Barva obálky volala `hasDigitalFile`, tedy synchronní kontrolu cesty na disku, při vykreslení obálky i titulku karty. | `Theme.coverAccents` používá uložený stav katalogu. Kontrola souboru zůstává v explicitních souborových operacích. |
| Vysoká | Konstrukce požadavku obálky a položky pro přetahování používala URL getter s kontrolou symlinků. I bez čtení obsahu tedy každý průchod view mohl přistupovat na disk. | Vykreslování sestaví pouze katalogovou URL. Obálka se validuje na workeru; přetažení provede jednu kontrolu až při skutečném exportu URL. Zachovány nativní reprezentace URL i ochrana před symlinkem mimo původní adresář. |
| Vysoká | Lazy mřížka si uchovávala `NSImage` ve stavu již opuštěných buněk; tyto silné reference obcházely rozpočet cache. | `BookCoverImageView` při zmizení uvolní obrázek. Při návratu ho načte ze sdílené cache nebo omezeného pracovního pořadníku. |
| Vysoká | Pořadník obálek načetl celé komprimované obrázky a uvolnil I/O slot před získáním CPU slotu. Fronta tak mohla držet mnoho velkých `Data` současně. | Přímé dekódování z URL; I/O a CPU slot platí až do dokončení operace. Dočasné objekty se uvolňují v `autoreleasepool`. |
| Vysoká | Náhled EPUB/MOBI nejprve dekódoval plnou obálku a teprve potom zmenšoval. | ImageIO zmenšuje již při dekódování na požadovanou úroveň. Zachována podpora SVG s omezeným rasterizováním a korekcí Retina pixelů. PDF používá velikost odpovídající požadavku. |
| Vysoká | MOBI/AZW3 extrakce obálky načítala nebo mapovala celý kontejner. `mappedIfSafe` může přejít na alokaci celého souboru. | Jeden společný parser pro `Data` a URL; souborová varianta čte pouze adresář záznamů, hlavičky, potřebné EXTH hodnoty a vybraný obrázek. Text ebooku přeskakuje pomocí seek. |
| Vysoká | Dávka změn odstraňovala a vkládala položky do výsledného pole jednu po druhé; náklady rostly přibližně jako počet změn × velikost výsledku. | Jedna kompilace podmínek a jedno sloučení změněných výsledků. Řazení pluginových výsledků také slučuje dávku najednou. |
| Vysoká | Zastaralý dotaz po zrušení dál procházel a řadil kandidáty. | Kontrolní body zrušení při procházení i řazení; částečné výsledky se nepublikují. |
| Vysoká | HTML import kontroloval konečný limit až po vytvoření všech náhrad. Opakované odkazy na stejný obrázek mohly vytvořit gigabajty mezidat. | Jednoprůchodové sestavování `Data` s kontrolou limitu před každým přidáním; zachováno kódování, citace atributů a zrušení operace. |
| Vysoká | Údržba primárního a dalšího souboru jedné knihy změnila primární hash před kontrolou snapshotu sourozence, což zneplatnilo vlastní dávku. | Všechny vstupy se validují před první změnou. Knihy se načtou jednou za dávku místo dvou dotazů pro každý soubor. |
| Vysoká | Selhání uložení při obnově celé knihy z Time Machine shodilo proces: rollback SwiftData převáděl dosud nezmaterializované snapshoty vztahů na pole. | Vztahy se materializují uvnitř synchronní transakce před první změnou. Vlastní rollback zbytečně nepřipojuje smazané modely; jejich obnovu provede koordinátor. Původní pád reprodukován samostatným harness testem, celá sada obnovy poté prošla. |
| Vysoká | Release na této betaverzi Swiftu odmítal i běžné bezpečné názvy souborů. Samostatný reproduktor prokázal nesprávnou optimalizaci při souběhu `contains(where:)` a `allSatisfy` nad bound metodami `CharacterSet.contains`; Debug ji neměl. | Explicitní průchody znaky obcházejí vadnou specializaci. Pravidla Unicode, zakázaných řídicích znaků a identifikátorů Kindle zůstávají zachována. Calibre sdílí validátor bezpečného komponentu cesty. |
| Střední | Změna primárního souboru, hashe nebo velikostní úrovně nemusela změnit identitu úlohy obálky. Cache mohla vracet i starý „obálka nenalezena“ výsledek. | Identita požadavku a revize cache zahrnují vlastníka, verzi, identitu a obsah zdroje i velikost náhledu. Staré čekající požadavky se zneplatní. |
| Střední | Cache počítala velikost obrázku v bodech, i když měl mnohem větší bitmapu v pixelech. | Zmenšení a rozpočet vycházejí ze skutečných pixelů. Stejný pixelový limit nyní dodržuje i obálka připravená při konverzi. |
| Střední | Změna jednoho záznamu znovu sestavovala zdrojové pořadí a indexy celého katalogu; sidebar upravoval nesouvisející skupiny. | Stávající pořadí se používá při změně metadat. Facety se upravují podle skutečně změněných polí. Projekce má UUID → pozice index a znovu nepublikuje stejné instance modelů. |
| Střední | Více překrývajících se generací mohlo aplikovat změnu s neaktuálním starým záznamem a nechat v indexu staré hodnoty. | Odstranění se řídí skutečně přítomným záznamem v actoru. Regrese ověřuje i filtrování přítomnosti na Kindle. |
| Střední | Po změně členství nesouhlasilo uložené `sourceOrdinal` s aktuálním pořadím; shodné sortovací klíče mohly měnit pořadí jinak v různých cestách. | Přírůstkové sloučení používá aktuální mapu zdrojových pozic. Test porovnává výsledek s úplným přepočtem. |
| Střední | Přepočet „Nedávno přidané“ skenoval data při každé změně a mohl minout expiraci mezi výpočtem a publikací. | Přepočet až při překročení relevantní hranice nebo návratu hodin zpět. Facety a plán expirací používají stejný časový okamžik. |
| Střední | Počty uložených hledání v sidebaru nereagovaly na samostatnou změnu poznámek, umístění na polici či roku. | Uložená hledání sledují normalizovaná prohledávaná pole; strukturované chytré police si ponechávají užší závislosti. |
| Střední | Zachytávání stovek vztahově bohatých SwiftData modelů najednou mohlo dlouho držet hlavní actor. | Zachytávání spolupracuje s plánovačem po přibližně 4 ms. Jednotlivý synchronní fetch či fault tento interval stále může překročit. |
| Střední | Kontrola velkého EPUB/PDF sdílela kompletní `Data` mezi hashem a parserem bez horního omezení. | Sdílení je omezeno na 32 MiB; větší soubory se hashují proudově a parser pracuje s URL. |
| Střední | Existující velikost assetu a nulová zrcadlená velikost knihy vedly k trvale neplatnému snapshotu údržby. | Snapshot porovnává skutečný původní údaj knihy; údržba může chybějící zrcadlo opravit. |
| Nižší | Klávesová navigace v mřížce hledala pozici knihy lineárním průchodem. Výběr přestavoval množinu všech zobrazených ID. | Navigace dostává index přímo z enumerace se zachovanou identitou knihy. Množina zobrazených ID se mění až s výsledky. |
| Nižší | Logika způsobilosti akcí měla tři kopie a několik průchodů nad stejným výběrem. | Jediná katalogová funkce pro mřížku, tabulku a hlavní nabídky; jeden průchod bez pomocných filtrovaných polí. |
| Nižší | Inspector vytvářel všechny řádky zvýraznění současně. | Zvýraznění se vykreslují v lazy kontejneru; zůstává dostupný celý obsah. |
| Nižší | Úklid osiřelých děl prováděl dotaz na počet v každé dávce a samostatný fetch pro každé dílo. | Konec určuje velikost načtené stránky, mazání načítá kandidáty dávkově. Obnova konkrétního díla také používá cílený UUID dotaz. |

## Refaktor a zachování funkcí

Sdílený `LibraryQuery.Matcher` nahrazuje několik implementací stejných pravidel a normalizuje operandy jednou. `BookActionAvailability.forBooks` sjednocuje pravidla digitálních a papírových knih, DRM, konverze a přítomnosti na čtečce. `CoverWorkScheduler.storedImage/runImageWork` spojuje dříve zdvojené načítání uložených a odvozených obálek. MOBI má jeden parser nad dvěma způsoby čtení.

Mřížka zachovává dvojklik, výběr, drag-and-drop, kontextové nabídky, přístupnost a navigaci klávesnicí. Nová samostatná buňka zužuje pozorování focusu a stavů služeb. Výběr stále může invalidovat nadřazený `LibraryView`, který vykresluje inspector a panel výběru; samotné rozdělení na buňky není důkazem nulového překreslování rodiče.

Refaktor odstraňuje duplicitní produkční logiku. Opravy parserů, rušení, dávkování a nové regresní/diagnostické testy však přidávají potřebný kód. Audit netvrdí, že celkový počet řádků v pracovním stromu klesl.

## Ověření

Proběhlo samostatné ověření souborového MOBI parseru na 3GB sparse souboru. Instrumentovaný čtecí adaptér přečetl 562 bajtů z kontejneru o 3 221 225 894 bajtech a vrátil správnou obálku. Tento výsledek dokládá výběrové čtení připraveného kontejneru; není to benchmark fyzického kopírování 3 GB ani všech struktur MOBI.

Regresní HTML fixture obsahuje 10 000 odkazů na tentýž obrázek. Potenciální expanze přes 13 GB je nyní odmítnuta před překročením výstupního limitu; cílený Debug test skončil přibližně za 14 ms. Ověřena je rovněž práce s Unicode, opakovanými obrázky a zrušením.

Testy obálek zahrnují skutečné pixelové rozměry, změnu revize po cachovaném neúspěchu, zneplatnění rozpracované úlohy, 48 souběžných požadavků při zachování limitu workerů, EPUB s PNG i SVG a Retina výstup. Testy indexu porovnávají přírůstkové změny s úplným výpočtem, včetně 1 000 změn v jedné dávce, změny pořadí, časových hranic a překrývajících se generací.

Závěrečný Debug funkční běh: **978 úspěšných testů, 0 selhání, 2 vypnuté opt-in benchmarky** podle `xcresulttool`. Swift Testing počítá i vypnuté testy a uvádí 980 testů ve 112 sadách, 39,306 s. Samostatná sada Time Machine: **21 úspěšných testů, 0 selhání**, včetně dříve padajícího rollbacku. Několik dalších testů ověřuje záměrně poškozené databáze; diagnostické řádky CoreData o jejich otevření samy o sobě nejsou selháním testu.

Závěrečný Release běh: **979 úspěšných testů, 0 selhání, 1 vypnutý opt-in corpus benchmark** podle `xcresulttool`. Swift Testing uvádí 980 testů ve 112 sadách, 36,587 s. Benchmark indexu byl v tomto běhu zapnut. Prošly i opravené kontroly názvů souborů, bezpečný export URL včetně serializace a původně padající obnova vztahů.

Souběžné testy různých sestav stejného bundle ID se dříve vzájemně ovlivnily; takový UI běh byl zastaven a není použit pro výkonové závěry. Závěrečné běhy proběhly sekvenčně. Výsledkové balíčky jsou `/private/tmp/WinstonPerformanceDebugComplete-20260907.xcresult` (funkční sada prošla, starší UI očekávání selhalo), `/private/tmp/WinstonBrowsingFinal-20260907.xcresult` (opravený samostatný UI test prošel) a `/private/tmp/WinstonPerformanceReleaseFinal-20260907.xcresult` (kompletní Release regrese prošla).

### Optimalizovaný index

Měření 7. září, Release `-O`, immutable metadata připravená mimo měřený interval. Každý dotaz ověřuje pořadí proti referenčnímu výpočtu a očekávaný počet výsledků. Dataset má různé názvy, 250 autorů a přesně 1 % rozečtených knih. Jde o jeden běh každé velikosti, ne o statistiku p95 či benchmark načtení ze SwiftData.

| Operace | 1 000 knih | 10 000 knih | 50 000 knih |
| --- | ---: | ---: | ---: |
| Sestavení indexu | 2,53 ms | 26,54 ms | 145,62 ms |
| Všechny knihy, zdrojové pořadí | 0,31 ms | 4,35 ms | 23,41 ms |
| Tag + autor + formát, 100 % výsledků | 0,54 ms | 6,30 ms | 34,34 ms |
| Textové hledání + řazení názvu, 100 % výsledků | 2,68 ms | 29,64 ms | 169,49 ms |
| Rozečtené, 10 / 100 / 500 výsledků | 0,04 ms | 0,33 ms | 1,76 ms |
| Dávkové odstranění 1 000 záznamů | 2,95 ms | 4,22 ms | 6,48 ms |

Přibližně 170 ms u širokého řazeného dotazu není bezprostřední odpověď. Výpočet běží v odděleném actoru a respektuje rušení; nenahrazuje měření odezvy hlavního vlákna při současném scrollování. Tabulka pochází z posledního úspěšného Release běhu.

### Skutečné procházení mřížky: funkčně prošlo, záseky zůstávají

Samostatný UI test `WinstonBrowsingFinal-20260907.xcresult` prošel za 66,512 s. Ověřil výběr kliknutím, posun focusu šipkou a výběr mezerníkem, skutečné zmizení první knihy z viditelné oblasti po scrollování, návrat k začátku a zachování vybrané knihy. Závěrečný screenshot byl prohlédnut: zobrazuje znovu načtené šedé JPEG obálky připraveného datasetu, ne fallbackovou grafiku. Test používá 1 000 papírových knih s uloženými obálkami a in-memory SwiftData, tedy neměří cold-start persistentního katalogu ani souběžné rozbalování ebooků.

| Metrika, dvě měřené iterace | Výsledek |
| --- | --- |
| Celá smyčka 12 scrollů dolů a 12 nahoru | 16,200 / 16,280 s |
| Počet záseků (`XCTHitchMetric`) | 434 / 477 |
| Součet doby záseků | 5,117 / 5,400 s |
| Podíl záseků | 308,43 / 323,02 ms za sekundu |
| Špička fyzické paměti | 392 824 / 390 678 kB |
| Absolutní fyzická paměť | 272 025 / 265 291 kB |

**Cíl procházení bez záseků tímto měřením splněn není.** Je to Debug na beta OS/toolchainu se syntetickými vstupy; čísla nejsou odhadem Release FPS. Nelze je však ignorovat ani úspěch funkčního testu prezentovat jako úspěch výkonového cíle. Test dosud nemá schválenou výkonovou baseline či fail limit na hitch ratio.

Při první verzi testu přišly klávesové vstupy před dokončením rozpoznání jednotlivého kliknutí vedle dvojkliku. Video doložilo opožděné dokončení prvního výběru. Test nyní čeká na pozorovatelný stav výběru, nikoli pevný sleep. Změna samotné interakce jednoduchého/dvojitého kliknutí zůstává případnou navazující UX prací.

## Reprodukce

Kompletní funkční regrese:

```sh
xcodebuild test -workspace Winston.xcworkspace -scheme Winston \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:WinstonTests
```

Optimalizovaný benchmark indexu na 1 000, 10 000 a 50 000 immutable záznamech; kontroluje také správnost výsledků. Příprava vstupních záznamů není součástí měřené stavby indexu. Časové výsledky se zapisují s prefixem `PERF immutable`:

```sh
xcodebuild build-for-testing \
  -workspace Winston.xcworkspace -scheme Winston -configuration Release \
  -destination 'platform=macOS' ENABLE_TESTABILITY=YES \
  SWIFT_COMPILATION_MODE=singlefile -derivedDataPath build/ReleaseDD

# Pouze ad hoc měřicí produkt; nemění oprávnění distribuované aplikace.
codesign --force --deep --sign - \
  --entitlements Scripts/LibraryPerformance.entitlements \
  build/ReleaseDD/Build/Products/Release/Winston.app

TEST_RUNNER_WINSTON_PERFORMANCE_BENCHMARKS=1 xcodebuild test-without-building \
  -workspace Winston.xcworkspace -scheme Winston -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/ReleaseDD \
  -only-testing:WinstonTests/LibraryReadModelTests/immutableIndexedQueryScalingBenchmark
```

Skutečná mřížka, 1 000 uložených obálek 800 × 1 200 pixelů, izolovaný root, kontrola odscrollování a návratu, měření paměti a záseků:

```sh
xcodebuild test -workspace Winston.xcworkspace -scheme Winston \
  -configuration Debug -destination 'platform=macOS' \
  -only-testing:WinstonUITests/WinstonUITests/testBrowsingLargeLibraryRetainsSelectionAndReturnsToLoadedCovers
```

Existující workflow `Scripts/profile-library-ui.sh` a `docs/LibraryUIPerformanceVerification.md` umožňuje navazující měření persistentního katalogu pomocí Instruments, počítání SQL a signpostů. Jeho mutační scénáře se nesmí zaměňovat s měřením plynulosti scrollování ani s benchmarkem čistého indexu.

## Zbývající hranice

- Počáteční projekce stále načítá celý katalog SwiftData včetně vztahů. Paměť na metadata a první načtení nejsou konstantní vůči počtu záznamů. Další architektonický krok pro statisíce až miliony knih je stránkovaná databázová projekce s odděleným detailem vztahů.
- Rozpočet `NSCache` pro obrázky je 96 MiB, nejvýše 4 096 položek. Jde o politiku cache, nikoli limit celé aplikace nebo absolutní záruku okamžitého uvolnění paměti frameworkem. Viditelné obrázky, SwiftUI, SwiftData a právě běžící dekodéry potřebují další paměť.
- Odvozené obálky se ukládají do `Application Support/Winston/DerivedCovers`. Jsou obnovitelné, ale nemají automatické prořezávání podle diskového rozpočtu. Není to OS-spravovaný adresář `Caches`.
- Hashování obsahu, import a ověřené zálohování nutně rostou s počtem bajtů. Proudové zpracování omezuje paměť, nikoli potřebný čas čtení disku.
- Beta OS/Xcode a zatížení stroje ovlivňují absolutní časy. Čas běhu XCTest scroll smyčky zahrnuje syntézu vstupů a čekání na idle; nelze ho prezentovat jako FPS. Záseky je nutné posuzovat podle příslušné metriky a skutečně provedeného scrollování.
- Bez stejného vstupního datasetu a stejné konfigurace před úpravou není poctivé uvádět procentuální zrychlení celé aplikace. Uvedené změny složitosti jsou podložené cestami v kódu a regresními testy, naměřené časy platí pro popsané scénáře.

## Co zbývá udělat, podle priority

1. **Doprofilovat a odstranit zbývající záseky scrollování.** Zpřístupnit izolovanou scroll fixture optimalizovanému UI hostu a zopakovat ji s Time Profiler/SwiftUI Instruments. Rozlišit hlavní vlákno, aktualizace buněk, layout, vykreslování stínů a dekódování obálek; další opravu vybrat podle naměřeného podílu. Současný Debug výsledek je vysoký a Release ekvivalent nebyl změřen.
2. **Stránkovat počáteční databázovou projekci.** Oddělit lehká metadata seznamu od relací potřebných jen pro inspector; připravovat index mimo hlavní actor. Nejvyšší priorita pro škálování samotného katalogu. Ověřovat na persistentních 50 000+ knihách s vydáními, soubory a zvýrazněními, ne pouze na poli hodnot v paměti.
3. **Zavést diskový rozpočet odvozených obálek.** Ukládat informaci o využití a uklízet po dávkách mimo hlavní vlákno. Mazat pouze obnovitelné odvozené náhledy, nikdy originály ani vlastní obálky uživatele. Současná oprava omezuje bitmapovou cache, ne velikost tohoto adresáře.
4. **Doplnit dlouhodobou výkonnostní regresi a limity.** Release, studená i teplá cache, několik průchodů velkým katalogem, návrat zpět a současná údržba/import. Sledovat hlavní vlákno, záseky, špičku i ustálení paměti, SQL a rušení dotazů. Dvě automatizované scrollovací iterace nejsou záruka pro libovolnou knihovnu.
5. **Změřit sdílené invalidace výběru.** Rodič knihovny stále reaguje kvůli inspectoru a panelu akcí; buňky tento vztah samy neodstraní. Další rozdělení má vycházet z počtu a ceny aktualizací ve SwiftUI Instruments, ne z počtu struktur ve zdrojáku. Ověřit také odezvu jednotlivého kliknutí při zachování dvojkliku a modifikátorů výběru.
6. **Zopakovat měření na stabilním toolchainu a cílovém úložišti.** Ověřit standardní WMO Release build/testy po opravě betaverze kompilátoru. Ponechat regresní kontroly bezpečných názvů a tokenů Kindle; compiler workaround neodstraňovat jen proto, že Debug funguje.
7. **Pevně nastavit geometrii UI fixture.** `AppSettings` čte zoom pomocí `object(forKey:) as? Double`; launch argument `-gridZoom 0` může přijít jako řetězec a nepřebít výchozí zoom. Závěrečný screenshot měl dva velké sloupce. Pro srovnávací matici je potřeba explicitně ověřit zoom i rozměry okna a nespoléhat na tento argument.

Tato navazující práce nebyla vydávána za dokončenou. Změny nebyly commitnuty ani instalovány přes uživatelovu aplikaci; skutečná knihovna se pro testování nepoužila.
