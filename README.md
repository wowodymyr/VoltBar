# VoltBar

VoltBar — андервольтинг Intel Mac из строки меню. Это полный аналог [VoltageShift](https://github.com/sicreative/VoltageShift) с GUI.
Использует тот же `VoltageShift.kext` (класс `VoltageShiftAnVMSR`), но всю пользовательскую логику пишет заново:

* **Меню в меню-баре** (иконка ⚡): шесть ползунков смещения напряжения (CPU, GPU, CPU Cache, System Agent, Analog I/O, Digital I/O), Turbo Boost, PL1/PL2, модель CPU, живые температура, частота и мощность пакета, кнопки **Save** и **Reset**.
* **Root-демон** `com.voltbar.daemon` (launchd) применяет профиль:
  * при загрузке системы;
  * после выхода из сна и гибернации (подписка на `IORegisterForSystemPower`, применение через 2 с и проверка через 15 с);
  * каждые 30 с проверяет, что значения на месте, и при расхождении восстанавливает их. У VoltageShift такая проверка по умолчанию раз в 160 минут.
* **CLI** `voltbarctl` с командами `info`, `mon`, `offset`, `turbo`, `power`, `read`, `write` и `--damage`, как у voltageshift.

> ⚠️ Инструмент для опытных пользователей. Слишком сильный андервольт даёт зависания и паники, повышение напряжения (положительное смещение) может повредить CPU.

## Что поддерживается (как у VoltageShift)

| Функция | VoltageShift | VoltBar |
|---|---|---|
| Смещение 6 плоскостей через OC Mailbox (MSR 0x150) | `offset` | ползунки / `voltbarctl offset` |
| Диапазон смещения | −250…0 мВ, `--damage` для выхода за него | −250…+250 мВ (ползунок с нулём посередине), damage: −500…+500 мВ |
| Turbo Boost (MSR 0x1A0, бит 38) | `turbo 0/1` | Заводское / Вкл / Выкл |
| PL1/PL2 (MSR 0x610) | `power` | ползунки / `voltbarctl power` |
| info / mon (частота, температура, мощность) | ✓ | в меню / `voltbarctl info`, `mon` |
| read / write MSR | ✓ | `sudo voltbarctl read/write` |
| Автоприменение при загрузке | `buildlaunchd` | ✓ |
| Восстановление после сна и гибернации | по таймеру | сразу по событию пробуждения + каждые 30 с |
| Защита от бутлупа | — | ✓ (см. ниже) |

Смещение кодируется точно по спецификации OC Mailbox: в единицах 1/1.024 мВ. VoltageShift кодирует с округлением до 1 мВ, поэтому при одинаковой цифре, например −100, VoltBar выставит примерно на 2 % меньше по модулю. Это и есть ровно −100 мВ.

## Защита от нестабильного андервольта

1. После **Save** профиль сразу применяется, но 10 минут считается неподтверждённым (в меню идёт обратный отсчёт). Если за это время система зависнет, упадёт в панику или будет перезагружена, при следующей загрузке профиль **не применится**, и в меню появится предупреждение.
2. **Kernel panic после сохранения** (в том числе позже 10 минут): демон находит отчёт `Kernel-*.panic` в `/Library/Logs/DiagnosticReports` и отключает профиль. Нестабильный андервольт часто роняет систему не под нагрузкой, а в простое (Machine Check в `machine_idle`).
3. Если демон стартует 4 раза подряд, проработав каждый раз меньше 3 минут (бутлуп), профиль тоже отключается.
4. **Reset** возвращает 0 мВ на всех плоскостях, заводские Turbo и PL1/PL2 и отключает профиль. Отключить профиль можно и тогда, когда драйвер не загружен.

Если хочешь перезагрузиться сразу после сохранения, подожди окончания отсчёта. Иначе профиль придётся сохранить ещё раз. Проверяй стабильность не только под нагрузкой (Cinebench, Prime95), но и в простое и при выходе из сна.

## Требования

* Intel Haswell или Broadwell Mac (проверялось на MacBookPro11,3 / i7-4850HQ на macOS 13.7), macOS 12 Monterey или новее.
* Разблокированный OC Mailbox (EFI пропатчен). Если в меню написано «OC Mailbox is not responding», смещения недоступны, но Turbo и PL работают.
* На macOS 12 галочка «Launch at login» создаёт `~/Library/LaunchAgents/com.voltbar.app.plist`, на 13 и новее используется системный `SMAppService`.
* Для сборки нужны Xcode или Command Line Tools, а также Kernel.framework из SDK (есть в Xcode).
* SIP с разрешёнными неподписанными kext (OCLP это настраивает, `csr-active-config` 03080000).

### Драйвер: свой kext VoltBarMSR

VoltBar больше не зависит от VoltageShift: в пакет входит свой драйвер `VoltBarMSR.kext` (исходник: `Kext/VoltBarMSR.cpp`). Пакет кладёт его в `/Library/Application Support/VoltBar/`, демон при старте загружает его через `kmutil load`.

Отличия от VoltageShift.kext:
* подключиться может только root;
* чтение MSR идёт через `rdmsr_carefully`: несуществующий регистр даёт ошибку, а не kernel panic;
* запись разрешена только в белый список регистров: OC Mailbox 0x150, PERF_CTL 0x199, MISC_ENABLE 0x1A0 (только бит Turbo, на всех ядрах), лимиты мощности 0x610 / 0x638 / 0x640. Зарезервированные биты и биты блокировки маскируются.

Если macOS при первой загрузке попросит разрешить расширение (Настройки → Конфиденциальность и безопасность), разреши и перезагрузись. Самый надёжный вариант — грузить kext через OpenCore: скопируй `VoltBarMSR.kext` в `EFI/OC/Kexts/` и добавь в `config.plist → Kernel → Add` запись `BundlePath = VoltBarMSR.kext`, `ExecutablePath = Contents/MacOS/VoltBarMSR`, `PlistPath = Contents/Info.plist`, `Enabled = true`. После обновления OCLP запись придётся добавить снова.

Если `VoltBarMSR` не загружен, демон умеет работать и через `VoltageShift.kext` (как запасной вариант). Какой драйвер используется, видно в окне настроек и в `voltbarctl info`.

## Сборка и установка

```bash
cd ~/Projects/VoltBar
./build.sh            # без sudo; результат: build/VoltBar-<версия>.pkg
open build/VoltBar-*.pkg
```

Дальше обычный установщик macOS. Пакет не подписан сертификатом Apple, поэтому при первом открытии может понадобиться правый клик → «Открыть». Можно и из терминала: `sudo installer -pkg build/VoltBar-*.pkg -target /`.

Пакет кладёт файлы сюда:

* `/Applications/VoltBar.app` (приложение). Автозапуск при входе включается галочкой в меню;
* `/Library/PrivilegedHelperTools/com.voltbar.daemon` и `/Library/LaunchDaemons/com.voltbar.daemon.plist` (демон);
* `/usr/local/bin/voltbarctl` (CLI);
* `/Library/Application Support/VoltBar/uninstall.sh` (удаление).

Если найден launchd `com.sicreative.VoltageShift`, установщик его отключает: два демона перебивали бы друг друга. Копия plist сохраняется в `/Library/Application Support/VoltBar/`, а `uninstall.sh` предложит её вернуть.

Удаление: `sudo "/Library/Application Support/VoltBar/uninstall.sh"` (сначала сбрасывает напряжения).

Иконка приложения генерируется скриптом `Tools/make-icon.swift` в `Resources/AppIcon.icns`. Чтобы перерисовать её, удали этот файл и запусти `./build.sh`.

## Использование

Нажми ⚡ в строке меню. В компактном меню есть CPU, GPU, Turbo и кнопки. Остальные плоскости, damage mode, лимиты мощности и настройки строки меню (показ температуры и мощности CPU рядом с ⚡) находятся в окне **All settings…**. Подвигай ползунки и нажми **Save**. Значения применяются сразу. Подпись «now» показывает то, что реально стоит в железе. Иконка ⚡ залита, когда профиль активен.

Подбирать значения удобно с CLI. Временные настройки действуют до перезагрузки:

```bash
voltbarctl info
voltbarctl offset -80 -50          # CPU −80, GPU −50
voltbarctl mon                     # следить за частотой, температурой, мощностью под нагрузкой
voltbarctl save                    # всё стабильно — сделать постоянным
voltbarctl reset
```

Ориентир для i7-4850HQ: обычно стабильно CPU −50…−100 мВ, Cache на том же уровне, GPU −30…−60 мВ. Каждый экземпляр CPU индивидуален, начинай с малого и проверяй под нагрузкой (Prime95, Cinebench, игры).

## Устройство

```
VoltBar.app / voltbarctl ──JSON по Unix-сокету /var/run/com.voltbar.daemon.sock (root:admin 0660)──▶ voltbard (root)
                                                                                                 │ IOConnectCallStructMethod
                                                                                                 ▼
                                                                                     VoltageShift.kext (RDMSR/WRMSR)
```

* Подключаться к сокету могут только пользователи группы admin. Сырые `read`/`write` MSR разрешены только root (`sudo`).
* Конфиг лежит в `/Library/Application Support/VoltBar/config.json`, служебное состояние в `state.json`, лог в `/Library/Logs/VoltBar.log`.

## Известные ограничения

* Apple дополнительно ограничивает мощность через MMIO (MCHBAR). Если там лимит ниже, поднятие PL1/PL2 через MSR может не дать эффекта. VoltageShift в этом месте ведёт себя так же.
* Turbo-бит пишется на том ядре, где выполняется kext, как и у VoltageShift.

## Лицензия

GPL-3.0. VoltageShift.kext © sicreative, основан на AnVMSR (Andy Vandijck).
