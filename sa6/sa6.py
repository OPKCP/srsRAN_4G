#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SA6 — программное управление спектрометр-анализатором/генератором Arinst SA6
============================================================================

Устройство Arinst SA6 ("6G Spectrum Analyzer", VID 0483 / PID 5740,
STMicroelectronics Virtual COM Port) работает по простому ASCII-протоколу
поверх виртуального COM-порта на 115200 бод, CR/LF.

Протокол описан в официальном документе "Arinst protocol" (arinst.ru/files/Protocol.zip).

Команды (ASCII, "<command> <arg1> ... <index>\\r\\n"):
  gon <idx>                        — включить генератор
  gof <idx>                        — выключить генератор
  scf <freq_Hz> <idx>              — установить частоту генератора
  sga <formatted_amp> <idx>        — установить выходную мощность генератора
  scn20 <start> <stop> <step> <timeout> <samples> <iffreq> <att> <idx>
                                   — сканирование спектра без сопровождения (tracking)
  scn22 ...                        — сканирование спектра с tracking-генератором

Декодирование амплитуд: каждая точка — 2 байта.
  16-бит значение = (byte[i] << 8) | byte[i+1]
  index (5 старших бит)  = (val & 0b1111100000000000) >> 11  — проверка целостности
  data  (11 младших бит) = val & 0b0000011111111111
  amplitude = (80.0*10.0 - data) / 10.0 + attenuation (дБм)
"""
from __future__ import annotations

import argparse
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

import serial

# Константы прошивки (из официального протокола)
BAUDRATE = 115200
INTERMEDIATE_FREQ = 10_700_000   # ПЧ, аппаратная константа
POINT_TIMEOUT = 200              # задержка установки синтезатора частоты (не менять)
POINT_ADC_SAMPLES = 20           # число сэмплов АЦП на точку

# Аппаратный диапазон
F_MIN = 35_000_000
F_MAX = 6_200_000_000

# Профили лабораторного стенда srsRAN_4G (E-UTRA Band 3, FDD 1800 МГц).
# DL — eNB передаёт непрерывно (~1811-1822 МГц, EARFCN 1260-1375).
# UL — UE передаёт импульсно (~95 МГц ниже DL: ~1716-1727 МГц).
LAB = {
    "dl": dict(name="DL eNB 1815 МГц (Band3)", start=1_808_000_000,
               stop=1_828_000_000, step=100_000, att=0),
    "ul": dict(name="UL UE 1720 МГц (Band3)", start=1_713_000_000,
               stop=1_733_000_000, step=100_000, att=0),
}


class SA6Error(Exception):
    """Ошибка обмена с устройством."""


def _format_attenuation(attenuation_db: int) -> int:
    """Внутренний аттенюатор 0..30 дБ -> формат протокола = 10000 - att*100.

    По официальному протоколу аттенюатор задаётся значением 0..-30 дБ,
    а формат = (attenuation * 100) + 10000. Например -15 дБ -> 8500.
    Здесь мы принимаем положительное число дБ (0..30) и инвертируем знак.
    """
    return 10000 - attenuation_db * 100


def _format_generator_output(output_dbm: float) -> int:
    """Выход генератора -15..-25 дБм -> формат протокола = (amp+15)*100 + 10000."""
    return int((output_dbm + 15) * 100 + 10000)


@dataclass
class ScanResult:
    frequencies: List[float]     # Гц
    amplitudes: List[float]      # дБм
    elapsed_ms: float = 0.0

    def peak_indices(self, threshold_db: Optional[float] = None,
                     min_distance_hz: float = 1_000_000) -> List[int]:
        """Индексы локальных максимумов спектра (пиков излучения).

        threshold_db — порог; если задан, пик учитывается только если
        его амплитуда >= threshold. default = медиана+10 дБ
        min_distance_hz — минимальная дистанция между пиками.
        """
        amp = self.amplitudes
        freq = self.frequencies
        if len(amp) < 3:
            return []
        if threshold_db is None:
            sorted_a = sorted(amp)
            threshold_db = sorted_a[len(sorted_a) // 2] + 10.0
        peaks = []
        i = 1
        while i < len(amp) - 1:
            if amp[i] >= amp[i - 1] and amp[i] >= amp[i + 1] and amp[i] >= threshold_db:
                if peaks:
                    # подавляем соседний пик ближе min_distance
                    idx, val, f0, a0 = peaks[-1]
                    if (freq[i] - f0) < min_distance_hz:
                        if amp[i] > a0:
                            peaks[-1] = (i, amp[i], freq[i], amp[i])
                        i += 1
                        continue
                peaks.append((i, amp[i], freq[i], amp[i]))
            i += 1
        return [p[0] for p in peaks]


class SA6:
    """Класс управления анализатором спектра Arinst SA6."""

    def __init__(self, port: str, baudrate: int = BAUDRATE,
                 timeout: float = 5.0, index: int = 0):
        self._ser = serial.Serial(port, baudrate, timeout=timeout,
                                  write_timeout=1.0)
        self._index = index
        self._flush()

    # ---------- низкоуровневый обмен ----------
    def _flush(self):
        self._ser.reset_input_buffer()
        self._ser.reset_output_buffer()

    def _next_index(self) -> int:
        idx = self._index
        self._index += 1
        return idx

    def _send(self, command: str, *args):
        args_s = " ".join(str(a) for a in args)
        line = f"{command}"
        if args_s:
            line += " " + args_s
        line += "\r\n"
        self._ser.write(line.encode("ascii"))
        self._ser.flush()

    def _read_line(self) -> str:
        raw = self._ser.readline()
        if not raw:
            raise SA6Error("Устройство не ответило (таймаут). Проверьте COM-порт.")
        return raw.decode("ascii", errors="replace").rstrip("\r\n")

    # ---------- генератор ----------
    def generator_on(self):
        idx = self._next_index()
        self._send("gon", idx)
        self._read_line()                       # "gon <idx>"
        complete = self._read_line()            # "complete"
        if "complete" not in complete:
            raise SA6Error(f"gon: неожиданный ответ: {complete!r}")
        self._flush()

    def generator_off(self):
        idx = self._next_index()
        self._send("gof", idx)
        self._read_line()
        self._read_line()
        self._flush()

    def generator_set_frequency(self, frequency_hz: int):
        if not (F_MIN <= frequency_hz <= F_MAX):
            raise ValueError(f"Частота вне диапазона {F_MIN}..{F_MAX} Гц")
        idx = self._next_index()
        self._send("scf", frequency_hz, idx)
        self._read_line()                       # "scf <idx>"
        status = self._read_line()              # "success"/"failure"
        self._read_line()                       # "complete"
        if "success" not in status:
            raise SA6Error(f"scf: не удалось установить частоту ({status!r})")
        self._flush()

    def generator_set_output(self, output_dbm: float):
        if not (-25 <= output_dbm <= -15):
            raise ValueError("Мощность генератора должна быть в диапазоне -15..-25 дБм")
        idx = self._next_index()
        self._send("sga", _format_generator_output(output_dbm), idx)
        self._read_line()                       # "sga <idx>"
        self._read_line()                       # "complete"
        self._flush()

    # ---------- сканирование ----------
    def _decode_scan(self, data: bytes, attenuation_db: int,
                     point_count: int) -> List[float]:
        # ищем конец потока: два байта 0xFF; длина = points*2 + 2 (терминатор)
        end = data.rfind(b"\xff\xff")
        if end < 0:
            raise SA6Error("Бинарный поток не найден (нет 0xFF 0xFF).")
        payload = data[:end]
        need = point_count * 2
        payload = payload[:need]
        amps = []
        for i in range(0, min(len(payload), need) - 1, 2):
            val = (payload[i] << 8) | payload[i + 1]
            data_enc = val & 0b0000011111111111
            # Официальный протокол: amplitude = (800 - data)/10 + attenuation
            amp = (80.0 * 10.0 - data_enc) / 10.0 + attenuation_db
            amps.append(amp)
        if len(amps) < point_count:
            raise SA6Error(f"Получено точек {len(amps)} из {point_count}.")
        return amps

    def scan(self, start_hz: int, stop_hz: int, step_hz: int,
             attenuation_db: int = 0, tracking: bool = False) -> ScanResult:
        if not (start_hz >= F_MIN and stop_hz <= F_MAX and step_hz > 0):
            raise ValueError(f"Некорректный диапазон/шаг в {F_MIN}..{F_MAX} Гц")
        if not (0 <= attenuation_db <= 30):
            raise ValueError("Аттенюатор должен быть 0..30 дБ")
        point_count = (stop_hz - start_hz) // step_hz + 1

        cmd = "scn22" if tracking else "scn20"
        idx = self._next_index()
        self._send(cmd, start_hz, stop_hz, step_hz, POINT_TIMEOUT,
                   POINT_ADC_SAMPLES, INTERMEDIATE_FREQ,
                   _format_attenuation(attenuation_db), idx)

        # ответ: "\r\n scn20 Start idx \r\n <data> <elapsed>\r\n complete\r\n"
        self._read_line()   # пустая строка "\r\n"
        header = self._read_line()  # "scn20 <start> <idx>"
        if cmd not in header:
            raise SA6Error(f"Неожиданный заголовок ответа: {header!r}")

        # читаем бинарный поток: points*2 + 2 байта
        data_len = point_count * 2 + 2
        binary = self._ser.read(data_len)
        if len(binary) < data_len:
            raise SA6Error(f"Бинарный поток обрезан: {len(binary)}/{data_len} байт")

        # остаток: "<elapsed_ms>\r\ncomplete\r\n"
        tail = self._read_line()
        complete = self._read_line()
        if "complete" not in complete:
            raise SA6Error(f"scan: неожиданный хвост: {complete!r}")

        self._flush()

        amps = self._decode_scan(binary, attenuation_db, point_count)
        freqs = [start_hz + i * step_hz for i in range(point_count)]
        elapsed = 0.0
        try:
            elapsed = float(tail.strip())
        except ValueError:
            pass
        return ScanResult(freqs, amps, elapsed)

    # ---------- пики ----------
    def find_peaks(self, start_hz: int, stop_hz: int, step_hz: int,
                   attenuation_db: int = 0, threshold_db: Optional[float] = None,
                   min_distance_hz: float = 1_000_000
                   ) -> List[Tuple[float, float]]:
        """Сканирование + обнаружение пиков излучения.

        Возвращает список (частота_Гц, амплитуда_дБм) отсортированных по убыванию амплитуды.
        """
        result = self.scan(start_hz, stop_hz, step_hz, attenuation_db)
        idxs = result.peak_indices(threshold_db, min_distance_hz)
        peaks = [(result.frequencies[i], result.amplitudes[i]) for i in idxs]
        peaks.sort(key=lambda p: p[1], reverse=True)
        return peaks

    # ---------- мониторинг (максимальное удержание) ----------
    def monitor(self, start_hz: int, stop_hz: int, step_hz: int,
                attenuation_db: int = 0, sweeps: int = 100,
                dwell_s: float = 0.05, on_sweep=None) -> ScanResult:
        """Непрерывный обзор с max-hold для поимки импульсного излучения (UL).

        Делает `sweeps` сканирований подряд и накапливает максимум амплитуды
        на каждой частоте. Это позволяет увидеть короткие UL-передачи UE,
        которые отдельный скан может пропустить.

        on_sweep — опциональный callback(result_scan) после каждого скана.
        Возвращает ScanResult с максимальными значениями.
        """
        amps = None
        for _ in range(sweeps):
            res = self.scan(start_hz, stop_hz, step_hz, attenuation_db)
            if amps is None:
                amps = list(res.amplitudes)
                freqs = list(res.frequencies)
            else:
                for i, a in enumerate(res.amplitudes):
                    if a > amps[i]:
                        amps[i] = a
            if on_sweep:
                on_sweep(res)
            if dwell_s:
                time.sleep(dwell_s)
        return ScanResult(freqs, amps)

    def close(self):
        if self._ser and self._ser.is_open:
            self._ser.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def _auto_port() -> Optional[str]:
    """Определяет COM-порт устройства по VID/PID STM (0483)."""
    try:
        import serial.tools.list_ports as lp
        for p in lp.comports():
            if p.vid == 0x0483 and (p.pid == 0x5740 or p.pid is None):
                return p.device
        return None
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser(description="Управление анализатором спектра Arinst SA6")
    ap.add_argument("--port", help="COM-порт (например COM3); по умолчанию автоопределение")
    ap.add_argument("--start", type=float, default=35, help="начальная частота, МГц (по умолч. 35)")
    ap.add_argument("--stop", type=float, default=1000, help="конечная частота, МГц (по умолч. 1000)")
    ap.add_argument("--step", type=float, default=1, help="шаг, МГц (по умолч. 1)")
    ap.add_argument("--att", type=int, default=0, help="внутренний аттенюатор 0..30 дБ")
    ap.add_argument("--peaks", action="store_true", help="искать пики излучения")
    ap.add_argument("--threshold", type=float, default=None, help="порог пика, дБм")
    ap.add_argument("--gon", action="store_true", help="включить генератор")
    ap.add_argument("--gof", action="store_true", help="выключить генератор")
    ap.add_argument("--freq", type=float, default=None, help="частота генератора, МГц")
    ap.add_argument("--power", type=float, default=None, help="мощность генератора, дБм (-15..-25)")
    ap.add_argument("--repeat", type=int, default=1, help="сколько сканирований выполнить")
    ap.add_argument("--profile", choices=["dl", "ul"], default=None,
                    help="профиль стенда: 'dl' (eNB ~1815 МГц) или 'ul' (UE ~1720 МГц); "
                         "заменяет --start/--stop/--step/--att на частоты стенда")
    ap.add_argument("--monitor", type=int, default=0, metavar="SWEEPS",
                    help="непрерывный обзор с max-hold (для ловли импульсного UL). "
                         "SWEEPS — число сканов для накопления")
    args = ap.parse_args()

    # Профиль стенда переопределяет диапазон/аттенюатор
    if args.profile:
        p = LAB[args.profile]
        print(f"Профиль: {p['name']}")
        args.start = p["start"] / 1e6
        args.stop = p["stop"] / 1e6
        args.step = p["step"] / 1e6
        args.att = p["att"]

    port = args.port or _auto_port()
    if not port:
        print("Не найден COM-порт устройства. Укажите --port.")
        return 1

    print(f"Подключение к {port} ...")
    try:
        sa6 = SA6(port)
    except serial.SerialException as e:
        print(f"ОШИБКА: не удалось открыть порт {port}.")
        print("  Устройство не отвечает или его драйвер неисправен.")
        print("  Проверьте в Диспетчере устройств, что анализатор определён как",)
        print("  'Устройство с последовательным интерфейсом USB (COMx)' без ошибки,")
        print(f"  затем повторите попытку. Технически: {e}")
        return 2
    with sa6:
        if args.gon:
            sa6.generator_on()
            print("Генератор: ВКЛ")
        if args.gof:
            sa6.generator_off()
            print("Генератор: ВЫКЛ")
        if args.freq is not None:
            sa6.generator_set_frequency(int(args.freq * 1e6))
            print(f"Генератор: частота {args.freq} МГц")
        if args.power is not None:
            sa6.generator_set_output(args.power)
            print(f"Генератор: мощность {args.power} дБм")

        start = int(args.start * 1e6)
        stop = int(args.stop * 1e6)
        step = int(args.step * 1e6)

        if args.monitor:
            print(f"\nМониторинг max-hold: {args.monitor} сканов, "
                  f"{start/1e6:.0f}-{stop/1e6:.0f} МГц, шаг {step/1e6} МГц ...")
            res = sa6.monitor(start, stop, step, args.att, sweeps=args.monitor)
            print(f"\nMax-hold спектр ({len(res.frequencies)} точек):")
            idxs = sorted(res.peak_indices(args.threshold),
                          key=lambda i: res.amplitudes[i], reverse=True)
            if idxs:
                print("ПИКИ (максимальные значения удержания):")
                for i in idxs:
                    print(f"  {res.frequencies[i]/1e6:10.3f} МГц   "
                          f"{res.amplitudes[i]:8.2f} дБм")
            else:
                print("  пиков не обнаружено.")
            return 0

        for r in range(args.repeat):
            res = sa6.scan(start, stop, step, args.att)
            if args.peaks:
                idxs = sorted(res.peak_indices(args.threshold),
                              key=lambda i: res.amplitudes[i], reverse=True)
                print(f"\nСкан #{r+1}  ({len(res.frequencies)} точек, "
                      f"{res.elapsed_ms:.0f} мс)  ПИКИ:")
                for i in idxs:
                    print(f"  {res.frequencies[i]/1e6:10.3f} МГц   "
                          f"{res.amplitudes[i]:8.2f} дБм")
            else:
                print(f"\nСкан #{r+1}  ({len(res.frequencies)} точек, "
                      f"{res.elapsed_ms:.0f} мс)")
                for f, a in zip(res.frequencies, res.amplitudes):
                    print(f"  {f/1e6:10.3f} МГц   {a:8.2f} дБм")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
