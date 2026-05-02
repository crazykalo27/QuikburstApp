#!/usr/bin/env python3
"""
Browse CSV/Excel time-series captures under NewMotorController.

- Pick a file from the folder (dropdown or Left/Right arrows).
- Plot every numeric column vs time in stacked subplots with a shared X axis.
- Toggle any subset of series on/off with the "Graphs" checkbox panel.
  All on / All off / Solo current quick buttons; Up/Down (or PgUp/PgDn) cycle
  "solo" through each series one-at-a-time.
- Set X (time) min/max for all plots at once.
- CSV: Cut overwrites the file with only rows in the current X range (plot zoom or min/max fields).
- CSV: Delete removes the current file from disk (with confirmation).
- From position: auto-detect “active” window (flat → moving → flat); show its duration on the
  position plot and mean i_motor / i_in over that time in the graph and a summary line above.
- On the i_motor and i_in graphs, a dashed line shows that active-window average (time span
  t_start…t_stop).
- Hover over a plot: a vertical line follows the pointer and a label shows time and the series
  value at that time (linear interpolation between samples).
"""

from __future__ import annotations

import tempfile
import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path
import sys

import numpy as np
import pandas as pd

import matplotlib
matplotlib.use("TkAgg")
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg, NavigationToolbar2Tk
from matplotlib.figure import Figure


SCRIPT_DIR = Path(__file__).resolve().parent
TIME_CANDIDATES = ("t_rel_s", "device_ms", "time_s", "time", "t_s", "timestamp", "host_unix_s")


def discover_data_files(root: Path) -> list[Path]:
    paths: list[Path] = []
    for pattern in ("**/*.csv", "**/*.xlsx", "**/*.xls"):
        paths.extend(root.glob(pattern))
    return sorted({p.resolve() for p in paths if p.is_file()}, key=lambda p: str(p).lower())


def pick_time_column(df: pd.DataFrame) -> str | None:
    for name in TIME_CANDIDATES:
        if name in df.columns:
            return name
    for col in df.columns:
        if pd.api.types.is_numeric_dtype(df[col]):
            return col
    return None


def y_numeric_columns(df: pd.DataFrame, time_col: str) -> list[str]:
    cols: list[str] = []
    for c in df.columns:
        if c == time_col:
            continue
        if pd.api.types.is_numeric_dtype(df[c]):
            cols.append(c)
    return cols


def _pick_position_column(df: pd.DataFrame) -> str | None:
    if "position_m" in df.columns:
        return "position_m"
    for c in df.columns:
        if "position" in c.lower():
            return c
    return None


def active_region_from_position(
    t: np.ndarray,
    pos: np.ndarray,
    vel: np.ndarray | None = None,
) -> dict | None:
    """Find t_start (flat → move) and t_stop (end of the one-way drop).

    t_stop is the **last** time before either (a) velocity reverses (bounce, wrong-way
    motion after a one-way test) or (b) sustained return to rest if no bounce.

    Current means use all samples with time in [t_start, t_stop] inclusive.
    """
    t = np.asarray(t, dtype=float)
    pos = np.asarray(pos, dtype=float)
    m = np.isfinite(t) & np.isfinite(pos)
    t = t[m]
    pos = pos[m]
    if len(t) < 8:
        return None
    if vel is not None:
        v = np.asarray(vel, dtype=float)
        v = v[m]
        if not np.all(np.isfinite(v)):
            v = np.gradient(pos, t, edge_order=1)
    else:
        v = np.gradient(pos, t, edge_order=1)
    v_abs = np.abs(v)
    # Noise floor: only the initial rest (first ~0.25 s), not a fraction of the whole
    # file — else long high-speed runs inflate the threshold and we never see "move".
    t0 = float(t[0])
    m_early = t <= t0 + 0.25
    if int(np.count_nonzero(m_early)) >= 3:
        v_noise = float(np.median(v_abs[m_early])) + 1e-12
    else:
        n_w = min(15, len(v_abs) - 1)
        v_noise = float(np.median(v_abs[: max(1, n_w)])) + 1e-12
    v_move = max(0.005, 5.0 * v_noise)
    v_flat = max(1e-5, 1.2 * v_noise)
    n_sus = max(2, min(5, len(t) // 80 + 1))

    def sustained(mask: np.ndarray, i: int, n: int, want: bool) -> bool:
        if i + n > len(mask):
            return False
        return bool(np.all(mask[i : i + n] == want))

    is_moving = v_abs > v_move
    is_flat = v_abs < v_flat

    i_start: int | None = None
    for i in range(0, len(t) - n_sus + 1):
        if sustained(is_moving, i, n_sus, True):
            i_start = i
            break
    if i_start is None:
        return None

    t_start = float(t[i_start])
    # Reference sign of the intended one-way move (e.g. drop direction).
    n_ref = min(2 * n_sus + 4, max(0, len(t) - i_start))
    if n_ref < 2:
        return None
    ref_sl = v[i_start : i_start + n_ref]
    med_ref = float(np.median(ref_sl))
    if abs(med_ref) < v_move * 0.4:
        for ii in range(i_start, min(i_start + 30, len(t))):
            if abs(v[ii]) > v_move:
                med_ref = float(v[ii])
                break
    s_ref: float
    if med_ref > v_flat * 0.5:
        s_ref = 1.0
    elif med_ref < -v_flat * 0.5:
        s_ref = -1.0
    else:
        s_ref = 0.0

    def median_opposite_from(i0: int) -> bool:
        if i0 + n_sus > len(v):
            return False
        seg = v[i0 : i0 + n_sus]
        if float(np.median(np.abs(seg))) < v_move * 0.4:
            return False
        med = float(np.median(seg))
        return med * s_ref < 0.0 and abs(med) > v_move * 0.4

    i_stop: int
    if s_ref != 0.0:
        i_rev = None
        for i in range(i_start + n_sus, len(t) - n_sus + 1):
            if median_opposite_from(i):
                i_rev = i
                break
        if i_rev is not None and i_rev - 1 >= i_start:
            i_stop = i_rev - 1
        else:
            i_stop = -1
    else:
        i_stop = -1

    if i_stop < 0:
        i_stop = None
        for i in range(i_start + n_sus, len(t) - n_sus + 1):
            if sustained(is_flat, i, n_sus, True):
                i_stop = i
                break
        if i_stop is None:
            i_stop = len(t) - 1
    t_stop = float(t[i_stop])
    if t_stop <= t_start:
        t_stop = float(t[-1])
    duration_s = t_stop - t_start
    return {
        "t_start": t_start,
        "t_stop": t_stop,
        "duration_s": duration_s,
        "i_start": i_start,
        "i_stop": i_stop,
    }


def mean_currents_in_window(
    df: pd.DataFrame,
    time_col: str,
    t_start: float,
    t_stop: float,
) -> tuple[float | None, float | None, int]:
    """Mean of i_motor and i_in for rows with time in [t_start, t_stop]. Count of rows used."""
    t = pd.to_numeric(df[time_col], errors="coerce")
    m = t.notna() & (t >= t_start) & (t <= t_stop)
    n = int(m.sum())
    if n == 0:
        return None, None, 0
    im, ii = None, None
    if "i_motor" in df.columns:
        imo = pd.to_numeric(df["i_motor"], errors="coerce")
        s = imo[m]
        if s.notna().any():
            im = float(s.mean())
    if "i_in" in df.columns:
        iin = pd.to_numeric(df["i_in"], errors="coerce")
        s = iin[m]
        if s.notna().any():
            ii = float(s.mean())
    return im, ii, n


def interp_y_at_time(t: np.ndarray, y: np.ndarray, xq: float) -> float:
    """Linear interpolation of (t,y) at time xq; t need not be sorted."""
    if not np.isfinite(xq):
        return float("nan")
    t = np.asarray(t, float)
    y = np.asarray(y, float)
    m = np.isfinite(t) & np.isfinite(y)
    t, y = t[m], y[m]
    if t.size < 1:
        return float("nan")
    o = np.argsort(t)
    t, y = t[o], y[o]
    if t.size == 1:
        return float(y[0])
    xq = float(np.clip(xq, t[0], t[-1]))
    i1 = int(np.searchsorted(t, xq, side="right"))
    i0 = i1 - 1
    i0 = int(np.clip(i0, 0, t.size - 1))
    i1 = int(np.clip(i1, 0, t.size - 1))
    if i0 == i1:
        return float(y[i0])
    t0, t1, y0, y1 = t[i0], t[i1], y[i0], y[i1]
    if t1 == t0:
        return float((y0 + y1) / 2.0)
    return float(y0 + (y1 - y0) * (xq - t0) / (t1 - t0))


def load_dataframe(path: Path, sheet: str | None) -> pd.DataFrame:
    suf = path.suffix.lower()
    if suf == ".csv":
        return pd.read_csv(path, low_memory=False)
    if suf in (".xlsx", ".xls"):
        kwargs: dict = {}
        if sheet is not None:
            kwargs["sheet_name"] = sheet
        return pd.read_excel(path, **kwargs)
    raise ValueError(f"Unsupported format: {path}")


def excel_sheet_names(path: Path) -> list[str] | None:
    if path.suffix.lower() not in (".xlsx", ".xls"):
        return None
    try:
        xl = pd.ExcelFile(path)
        return list(xl.sheet_names)
    except Exception:
        return None


class DataCaptureViewer(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("NewMotorController — capture viewer")
        self.geometry("1100x800")

        self._files = discover_data_files(SCRIPT_DIR)
        self._index = 0
        self._sheet_names: list[str] | None = None
        self._current_sheet: str | None = None
        self._df: pd.DataFrame | None = None
        self._time_col: str | None = None
        self._y_cols: list[str] = []
        self._t_full: tuple[float, float] = (0.0, 1.0)
        # Per-column visibility: one BooleanVar per numeric column, rebuilt on each
        # file load so column sets that differ between files don't stale-reference.
        # _solo_idx tracks keyboard-driven "solo cycling" through y_cols.
        self._series_visible: dict[str, tk.BooleanVar] = {}
        self._solo_idx: int = 0
        self._hover_cids: list[int] = []
        self._hover_track: list[dict] = []

        self._build_ui()
        self.bind("<Left>", lambda e: self._prev_file())
        self.bind("<Right>", lambda e: self._next_file())
        self.bind("<Prior>", lambda e: self._prev_series())  # Page Up
        self.bind("<Next>", lambda e: self._next_series())  # Page Down
        self.bind("<Up>", lambda e: self._prev_series())
        self.bind("<Down>", lambda e: self._next_series())

        if not self._files:
            messagebox.showwarning(
                "No data files",
                f"No .csv / .xlsx / .xls files found under:\n{SCRIPT_DIR}",
            )
        else:
            self._load_current_file()

    def _build_ui(self) -> None:
        top = ttk.Frame(self, padding=8)
        top.pack(side=tk.TOP, fill=tk.X)

        self._title_lbl = ttk.Label(top, text="", font=("TkDefaultFont", 12, "bold"))
        self._title_lbl.pack(anchor=tk.W)

        row1 = ttk.Frame(top)
        row1.pack(fill=tk.X, pady=(4, 0))
        ttk.Label(row1, text="File:").pack(side=tk.LEFT)
        self._file_combo = ttk.Combobox(
            row1,
            values=[self._display_path(p) for p in self._files],
            state="readonly",
            width=70,
        )
        self._file_combo.pack(side=tk.LEFT, padx=6, fill=tk.X, expand=True)
        self._file_combo.bind("<<ComboboxSelected>>", self._on_file_combo)
        ttk.Button(row1, text="◀ Prev", command=self._prev_file).pack(side=tk.LEFT, padx=2)
        ttk.Button(row1, text="Next ▶", command=self._next_file).pack(side=tk.LEFT, padx=2)

        self._sheet_row = ttk.Frame(top)
        ttk.Label(self._sheet_row, text="Sheet:").pack(side=tk.LEFT)
        self._sheet_combo = ttk.Combobox(self._sheet_row, state="readonly", width=40)
        self._sheet_combo.pack(side=tk.LEFT, padx=6)
        self._sheet_combo.bind("<<ComboboxSelected>>", self._on_sheet_combo)

        row2 = ttk.Frame(top)
        row2.pack(fill=tk.X, pady=(6, 0))
        ttk.Label(row2, text="Time axis (shared):").pack(side=tk.LEFT)
        ttk.Label(row2, text="min").pack(side=tk.LEFT, padx=(8, 2))
        self._tmin_var = tk.StringVar(value="")
        ttk.Entry(row2, textvariable=self._tmin_var, width=14).pack(side=tk.LEFT)
        ttk.Label(row2, text="max").pack(side=tk.LEFT, padx=(6, 2))
        self._tmax_var = tk.StringVar(value="")
        ttk.Entry(row2, textvariable=self._tmax_var, width=14).pack(side=tk.LEFT)
        ttk.Button(row2, text="Apply", command=self._apply_xlim).pack(side=tk.LEFT, padx=6)
        ttk.Button(row2, text="Reset (full range)", command=self._reset_xlim).pack(side=tk.LEFT, padx=2)
        ttk.Button(row2, text="Cut (crop CSV)", command=self._crop_current_csv).pack(side=tk.LEFT, padx=(12, 2))
        ttk.Button(row2, text="Delete file", command=self._delete_current_file).pack(side=tk.LEFT, padx=2)

        row2b = ttk.Frame(top)
        row2b.pack(fill=tk.X, pady=(2, 0))
        ttk.Label(
            row2b,
            text="Cut: keeps rows whose time column falls in the current X range (matplotlib zoom/pan or min/max above). Rewrites CSV; if t_rel_s exists it is re-zeroed to the crop start.",
            font=("TkDefaultFont", 8),
            foreground="#444",
            wraplength=900,
        ).pack(anchor=tk.W)

        graphs_fr = ttk.LabelFrame(top, text="Graphs (toggle which to show)", padding=6)
        graphs_fr.pack(fill=tk.X, pady=(6, 0))
        btn_row = ttk.Frame(graphs_fr)
        btn_row.pack(fill=tk.X, pady=(0, 4))
        ttk.Button(btn_row, text="All on", command=self._graphs_all_on).pack(side=tk.LEFT, padx=(0, 4))
        ttk.Button(btn_row, text="All off", command=self._graphs_all_off).pack(side=tk.LEFT, padx=(0, 4))
        ttk.Button(btn_row, text="Solo current", command=self._graphs_solo_current).pack(side=tk.LEFT, padx=(0, 12))
        ttk.Label(
            btn_row,
            text="↑ ↓ (or PgUp/PgDn) cycle solo through series.  ← → switch file.",
            font=("TkDefaultFont", 9),
            foreground="gray",
        ).pack(side=tk.LEFT)
        # Checkboxes land in this inner frame, rebuilt whenever columns change.
        self._graphs_checks_fr = ttk.Frame(graphs_fr)
        self._graphs_checks_fr.pack(fill=tk.X)

        stats_fr = ttk.LabelFrame(
            top,
            text="Sampling rate + uniformity (deltas between successive samples)",
            padding=4,
        )
        stats_fr.pack(fill=tk.X, pady=(6, 0))
        # Explicit colors: previously we reused the LabelFrame background, which on
        # macOS is a dynamic system color, and Text's default foreground stayed white
        # in dark mode → white-on-white and unreadable. Force a readable pair.
        self._stats_text = tk.Text(
            stats_fr,
            height=9,
            wrap=tk.NONE,
            font=("Menlo", 10),
            bd=1,
            relief=tk.SOLID,
            state=tk.DISABLED,
            background="#fafafa",
            foreground="#111111",
            insertbackground="#111111",
            highlightthickness=0,
        )
        self._stats_text.pack(fill=tk.X, expand=False)

        self._active_fr = ttk.LabelFrame(
            top,
            text="Active region (position: flat → move; end at reverse/bounce or rest)",
            padding=4,
        )
        self._active_fr.pack(fill=tk.X, pady=(4, 0))
        self._active_lbl = ttk.Label(
            self._active_fr,
            text="(no position column or not loaded)",
            wraplength=900,
            justify=tk.LEFT,
        )
        self._active_lbl.pack(anchor=tk.W)

        self._fig = Figure(figsize=(10, 8), dpi=100)
        self._fig.set_layout_engine("constrained")
        self._canvas = FigureCanvasTkAgg(self._fig, master=self)
        self._canvas.draw()
        self._canvas.get_tk_widget().pack(side=tk.TOP, fill=tk.BOTH, expand=True)
        self._toolbar = NavigationToolbar2Tk(self._canvas, self)
        self._toolbar.update()

    def _display_path(self, p: Path) -> str:
        try:
            return str(p.relative_to(SCRIPT_DIR))
        except ValueError:
            return str(p)

    def _on_file_combo(self, _evt=None) -> None:
        name = self._file_combo.get()
        for i, p in enumerate(self._files):
            if self._display_path(p) == name:
                self._index = i
                self._load_current_file()
                return

    def _on_sheet_combo(self, _evt=None) -> None:
        self._current_sheet = self._sheet_combo.get() or None
        self._reload_df_only()

    # --- Graph visibility ---------------------------------------------------

    def _rebuild_graph_checks(self) -> None:
        """Rebuild the per-column checkbox panel. Called when y_cols changes."""
        for child in self._graphs_checks_fr.winfo_children():
            child.destroy()
        # Keep previous visibility when a column persists across file reloads;
        # otherwise default-on for any newly seen column.
        new_vars: dict[str, tk.BooleanVar] = {}
        for col in self._y_cols:
            prev = self._series_visible.get(col)
            new_vars[col] = prev if prev is not None else tk.BooleanVar(value=True)
        self._series_visible = new_vars
        # Layout: 4 per row, left-to-right, top-to-bottom.
        per_row = 4
        for i, col in enumerate(self._y_cols):
            r, c = divmod(i, per_row)
            cb = ttk.Checkbutton(
                self._graphs_checks_fr,
                text=col,
                variable=self._series_visible[col],
                command=self._redraw,
            )
            cb.grid(row=r, column=c, sticky=tk.W, padx=(0, 12), pady=1)
        # Clamp solo cursor.
        if self._y_cols:
            self._solo_idx = min(self._solo_idx, len(self._y_cols) - 1)
        else:
            self._solo_idx = 0

    def _visible_cols(self) -> list[str]:
        return [c for c in self._y_cols if self._series_visible.get(c) and self._series_visible[c].get()]

    def _graphs_all_on(self) -> None:
        for v in self._series_visible.values():
            v.set(True)
        self._redraw()

    def _graphs_all_off(self) -> None:
        for v in self._series_visible.values():
            v.set(False)
        self._redraw()

    def _graphs_solo_current(self) -> None:
        """Leave only the current keyboard-solo column on; pick the first visible
        one if the solo cursor is stale."""
        if not self._y_cols:
            return
        visible = self._visible_cols()
        if visible:
            target = visible[0]
            self._solo_idx = self._y_cols.index(target)
        else:
            target = self._y_cols[self._solo_idx]
        for c, v in self._series_visible.items():
            v.set(c == target)
        self._redraw()

    def _prev_file(self) -> None:
        if len(self._files) <= 1:
            return
        self._index = (self._index - 1) % len(self._files)
        self._sync_file_combo()
        self._load_current_file()

    def _next_file(self) -> None:
        if len(self._files) <= 1:
            return
        self._index = (self._index + 1) % len(self._files)
        self._sync_file_combo()
        self._load_current_file()

    def _sync_file_combo(self) -> None:
        if self._files:
            self._file_combo.set(self._display_path(self._files[self._index]))

    def _prev_series(self) -> None:
        """Cycle solo to the previous column (shows only that graph)."""
        if not self._y_cols:
            return
        self._solo_idx = (self._solo_idx - 1) % len(self._y_cols)
        self._apply_solo(self._y_cols[self._solo_idx])

    def _next_series(self) -> None:
        """Cycle solo to the next column (shows only that graph)."""
        if not self._y_cols:
            return
        self._solo_idx = (self._solo_idx + 1) % len(self._y_cols)
        self._apply_solo(self._y_cols[self._solo_idx])

    def _apply_solo(self, target: str) -> None:
        for c, v in self._series_visible.items():
            v.set(c == target)
        self._redraw()

    def _load_current_file(self) -> None:
        if not self._files:
            return
        path = self._files[self._index]
        self._sync_file_combo()
        self._title_lbl.configure(text=self._display_path(path))

        sheets = excel_sheet_names(path)
        self._sheet_names = sheets
        if sheets and len(sheets) > 1:
            self._sheet_row.pack(fill=tk.X, pady=(4, 0))
            self._sheet_combo.configure(values=sheets)
            self._current_sheet = sheets[0]
            self._sheet_combo.set(self._current_sheet)
        else:
            self._sheet_row.pack_forget()
            self._current_sheet = sheets[0] if sheets else None

        try:
            self._df = load_dataframe(path, self._current_sheet)
        except Exception as e:
            messagebox.showerror("Load error", f"{path.name}:\n{e}")
            self._df = None
            self._clear_fig()
            self._refresh_stats()
            return

        self._prepare_columns()
        self._reset_xlim()
        self._refresh_stats()
        self._redraw()

    def _reload_df_only(self) -> None:
        if not self._files:
            return
        path = self._files[self._index]
        try:
            self._df = load_dataframe(path, self._current_sheet)
        except Exception as e:
            messagebox.showerror("Load error", f"{path.name}:\n{e}")
            self._df = None
            self._clear_fig()
            self._refresh_stats()
            return
        self._prepare_columns()
        self._reset_xlim()
        self._refresh_stats()
        self._redraw()

    def _prepare_columns(self) -> None:
        if self._df is None or self._df.empty:
            self._time_col = None
            self._y_cols = []
            self._rebuild_graph_checks()
            return
        self._time_col = pick_time_column(self._df)
        if self._time_col is None:
            self._y_cols = []
            self._rebuild_graph_checks()
            return
        self._y_cols = y_numeric_columns(self._df, self._time_col)
        self._rebuild_graph_checks()
        t = pd.to_numeric(self._df[self._time_col], errors="coerce")
        valid = t[np.isfinite(t)]
        if len(valid):
            self._t_full = (float(valid.min()), float(valid.max()))
        else:
            self._t_full = (0.0, 1.0)

    def _reset_xlim(self) -> None:
        lo, hi = self._t_full
        self._tmin_var.set(f"{lo:.6g}")
        self._tmax_var.set(f"{hi:.6g}")
        self._redraw()

    def _parse_lim(self, s: str) -> float | None:
        s = s.strip()
        if not s:
            return None
        try:
            return float(s)
        except ValueError:
            return None

    def _apply_xlim(self) -> None:
        self._redraw()

    def _clear_fig(self) -> None:
        self._teardown_hover()
        self._fig.clear()
        self._canvas.draw()

    # --- Sampling rate / uniformity -----------------------------------------
    # The export path in vesc_serial_control.py can emit rows either on a
    # uniform device_ms grid (default) or at TELEM cadence (jittery). This
    # panel verifies which you got and how evenly spaced it actually is.

    _UNIT_SCALE_MS = {
        # time-column name -> factor that converts its unit to ms
        "t_rel_s": 1000.0,
        "time_s": 1000.0,
        "t_s": 1000.0,
        "time": 1000.0,
        "host_unix_s": 1000.0,
        "device_ms": 1.0,
        "timestamp": 1.0,
        "enc_device_ms": 1.0,
    }

    def _unit_scale_for(self, col: str) -> tuple[float, str]:
        """Return (factor to ms, unit label) for the given time-like column."""
        if col in self._UNIT_SCALE_MS:
            s = self._UNIT_SCALE_MS[col]
            return s, ("ms" if s == 1.0 else "s")
        # Unknown — guess by typical range.
        return 1000.0, "s"

    @staticmethod
    def _fmt_delta_stats(deltas_ms: np.ndarray) -> list[str]:
        d = deltas_ms[np.isfinite(deltas_ms)]
        if d.size == 0:
            return ["    (no valid deltas)"]
        mean = float(d.mean())
        med = float(np.median(d))
        std = float(d.std(ddof=0))
        mn = float(d.min())
        mx = float(d.max())
        jitter = mx - mn
        hz = 1000.0 / mean if mean > 0 else 0.0
        cv = (std / mean * 100.0) if mean > 0 else 0.0
        # Classification: what we're actually asking is "are these evenly spaced?"
        # jitter (max-min) is the direct answer; stdev/CV is a summary.
        if jitter < 0.5 or (mean > 0 and jitter / mean < 0.01):
            verdict = "UNIFORM"
        elif cv < 5.0:
            verdict = "near-uniform"
        elif cv < 20.0:
            verdict = "jittery"
        else:
            verdict = "irregular"
        return [
            f"    mean  {mean:8.3f} ms   ({hz:7.2f} Hz)   median {med:8.3f} ms",
            f"    stdev {std:8.3f} ms   CV {cv:5.2f}%       min/max {mn:.3f}/{mx:.3f} ms",
            f"    jitter (max-min) {jitter:.3f} ms   →   {verdict}",
        ]

    @staticmethod
    def _mask_present(series: pd.Series) -> np.ndarray:
        """True where the cell has a usable value (not NaN, not empty string)."""
        vals = pd.to_numeric(series, errors="coerce")
        return vals.notna().to_numpy()

    def _deltas_ms_from(self, t_series: pd.Series, col: str, mask: np.ndarray | None = None) -> np.ndarray:
        scale, _unit = self._unit_scale_for(col)
        vals = pd.to_numeric(t_series, errors="coerce").to_numpy()
        if mask is not None:
            vals = vals[mask]
        vals = vals[np.isfinite(vals)]
        if vals.size < 2:
            return np.array([], dtype=float)
        return np.diff(vals) * scale

    def _compute_stats_text(self) -> str:
        df = self._df
        if df is None or df.empty or self._time_col is None:
            return "No data loaded."

        lines: list[str] = []
        n_rows = len(df)
        lines.append(f"Rows: {n_rows}    Columns: {len(df.columns)}    Time column: {self._time_col}")

        # --- Overall row cadence, based on the primary time column.
        scale, unit = self._unit_scale_for(self._time_col)
        t_num = pd.to_numeric(df[self._time_col], errors="coerce")
        t_valid = t_num[t_num.notna()].to_numpy()
        if t_valid.size >= 2:
            span_ms = (t_valid[-1] - t_valid[0]) * scale
            lines.append(
                f"Span:  {span_ms/1000.0:.3f} s   ({t_valid[0]:.4g} → {t_valid[-1]:.4g} {unit})"
            )
        deltas_all = self._deltas_ms_from(df[self._time_col], self._time_col)
        lines.append("")
        lines.append(f"• Overall CSV row cadence ('{self._time_col}'):")
        lines.extend(self._fmt_delta_stats(deltas_all))

        # --- TELEM-present rows (non-NaN rpm_vesc is the most reliable hint).
        telem_col = next(
            (c for c in ("rpm_vesc", "duty", "vbat", "i_motor", "i_in") if c in df.columns),
            None,
        )
        if telem_col is not None:
            mask = self._mask_present(df[telem_col])
            n_t = int(mask.sum())
            lines.append("")
            lines.append(
                f"• TELEM rows (non-empty '{telem_col}'): {n_t}/{n_rows} "
                f"({(100.0 * n_t / n_rows) if n_rows else 0:.1f}%)"
            )
            if n_t >= 2:
                lines.extend(
                    self._fmt_delta_stats(self._deltas_ms_from(df[self._time_col], self._time_col, mask))
                )

        # --- ENC-present rows paired into the CSV.
        enc_pair_col = next(
            (c for c in ("enc_device_ms", "enc_count", "position_m", "velocity_mps") if c in df.columns),
            None,
        )
        if enc_pair_col is not None:
            mask = self._mask_present(df[enc_pair_col])
            n_e = int(mask.sum())
            lines.append("")
            lines.append(
                f"• ENC-paired rows (non-empty '{enc_pair_col}'): {n_e}/{n_rows} "
                f"({(100.0 * n_e / n_rows) if n_rows else 0:.1f}%)"
            )
            if n_e >= 2:
                lines.extend(
                    self._fmt_delta_stats(self._deltas_ms_from(df[self._time_col], self._time_col, mask))
                )

        # --- Raw ENC firmware cadence, independent of CSV grid: look at the
        # enc_device_ms column itself. For grid CSVs multiple rows can share
        # the same nearest enc, so drop duplicates to see the real rate.
        if "enc_device_ms" in df.columns:
            e = pd.to_numeric(df["enc_device_ms"], errors="coerce").to_numpy()
            e = e[np.isfinite(e)]
            if e.size >= 2:
                uniq = np.unique(e.astype(np.int64))
                uniq_sorted = np.sort(uniq)
                deltas = np.diff(uniq_sorted).astype(float)
                deltas = deltas[deltas > 0]
                lines.append("")
                lines.append(
                    f"• Raw ENC firmware stream (unique 'enc_device_ms', {uniq_sorted.size} samples):"
                )
                if deltas.size >= 1:
                    lines.extend(self._fmt_delta_stats(deltas))

        return "\n".join(lines)

    def _refresh_stats(self) -> None:
        try:
            text = self._compute_stats_text()
        except Exception as e:
            text = f"Stats error: {e}"
        self._stats_text.configure(state=tk.NORMAL)
        self._stats_text.delete("1.0", tk.END)
        self._stats_text.insert(tk.END, text)
        self._stats_text.configure(state=tk.DISABLED)

    def _compute_active_region_summary(self) -> dict | None:
        """Detect flat→move→flat from position; set _active_lbl; return data for plot overlays."""
        df = self._df
        if df is None or self._time_col is None:
            return None
        pos_col = _pick_position_column(df)
        if pos_col is None:
            self._active_lbl.configure(
                text="No position column (expected position_m, or a column with 'position' in the name).",
            )
            return None
        t = pd.to_numeric(df[self._time_col], errors="coerce").to_numpy()
        pos = pd.to_numeric(df[pos_col], errors="coerce").to_numpy()
        vel: np.ndarray | None = None
        if "velocity_mps" in df.columns:
            vel = pd.to_numeric(df["velocity_mps"], errors="coerce").to_numpy()
        ar0 = active_region_from_position(t, pos, vel)
        if ar0 is None:
            self._active_lbl.configure(
                text=f"Position: {pos_col!r} — could not detect flat → motion → flat "
                "(try clearer rest before/after, or see thresholds in active_region_from_position).",
            )
            return None
        im, ii, n = mean_currents_in_window(df, self._time_col, ar0["t_start"], ar0["t_stop"])
        out: dict = {
            **ar0,
            "pos_col": pos_col,
            "mean_i_motor": im,
            "mean_i_in": ii,
            "n_rows": n,
        }
        segs: list[str] = [
            f"{pos_col}:  t_start={ar0['t_start']:.4f} s,  t_stop={ar0['t_stop']:.4f} s,  "
            f"Δt={ar0['duration_s']:.4f} s,  n={n} rows  |",
        ]
        if im is not None:
            segs.append(f"  avg i_motor = {im:.4f} A  |")
        if ii is not None:
            segs.append(f"  avg i_in = {ii:.4f} A")
        if im is None and ii is None:
            segs.append("  (add i_motor, i_in columns or no numeric data in window)")
        self._active_lbl.configure(text=" ".join(segs))
        return out

    def _effective_xlim(self) -> tuple[float, float]:
        lo, hi = self._t_full
        tmin = self._parse_lim(self._tmin_var.get())
        tmax = self._parse_lim(self._tmax_var.get())
        if tmin is None:
            tmin = lo
        if tmax is None:
            tmax = hi
        if tmax <= tmin:
            tmax = tmin + 1e-9
        return tmin, tmax

    def _crop_time_limits(self) -> tuple[float, float]:
        """Prefer the on-screen plot X limits (after zoom/pan); else min/max fields."""
        ax_list = self._fig.get_axes() if self._fig is not None else []
        if self._df is not None and self._time_col and len(ax_list) > 0:
            lo, hi = ax_list[0].get_xlim()
            a, b = float(min(lo, hi)), float(max(lo, hi))
            if np.isfinite(a) and np.isfinite(b) and b > a:
                return a, b
        return self._effective_xlim()

    def _crop_current_csv(self) -> None:
        if not self._files or self._df is None or self._time_col is None:
            messagebox.showinfo("Cut", "Nothing loaded.")
            return
        path = self._files[self._index]
        if path.suffix.lower() != ".csv":
            messagebox.showinfo("Cut", "On-disk crop is only supported for CSV files.")
            return

        tmin, tmax = self._crop_time_limits()
        t = pd.to_numeric(self._df[self._time_col], errors="coerce")
        mask = np.isfinite(t) & (t >= tmin) & (t <= tmax)
        n_keep = int(mask.sum())
        if n_keep == 0:
            messagebox.showwarning("Cut", "No rows fall in the current X range.")
            return
        n_drop = int(len(self._df) - n_keep)
        if not messagebox.askyesno(
            "Cut (crop CSV)",
            f"Overwrite file and keep only rows with {self._time_col!r} in [{tmin:g}, {tmax:g}]?\n\n"
            f"Keep: {n_keep} rows\nRemove: {n_drop} rows\n\n{path.name}",
        ):
            return

        cropped = self._df.loc[mask].copy()
        if "t_rel_s" in cropped.columns:
            hu = pd.to_numeric(cropped["host_unix_s"], errors="coerce") if "host_unix_s" in cropped.columns else None
            if hu is not None and hu.notna().any():
                t0 = float(hu.min())
                cropped["t_rel_s"] = hu - t0
            else:
                tr = pd.to_numeric(cropped["t_rel_s"], errors="coerce")
                if tr.notna().any():
                    cropped["t_rel_s"] = tr - tr.min()

        tmp_path: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                newline="",
                encoding="utf-8",
                delete=False,
                dir=path.parent,
                prefix=f".crop_{path.stem}_",
                suffix=".tmp.csv",
            ) as tmp:
                tmp_path = Path(tmp.name)
                cropped.to_csv(tmp, index=False)
            tmp_path.replace(path)
        except Exception as e:
            if tmp_path is not None:
                try:
                    tmp_path.unlink(missing_ok=True)
                except OSError:
                    pass
            messagebox.showerror("Cut failed", str(e))
            return

        messagebox.showinfo("Cut", f"Saved {n_keep} rows to {path.name}")
        self._reload_df_only()

    def _delete_current_file(self) -> None:
        if not self._files:
            return
        path = self._files[self._index]
        if not messagebox.askyesno(
            "Delete file",
            f"Permanently delete this file from disk?\n\n{path}",
        ):
            return
        try:
            path.unlink()
        except OSError as e:
            messagebox.showerror("Delete failed", str(e))
            return

        del self._files[self._index]
        if not self._files:
            self._df = None
            self._time_col = None
            self._y_cols = []
            self._file_combo.configure(values=[])
            self._rebuild_graph_checks()
            self._title_lbl.configure(text="")
            self._clear_fig()
            self._refresh_stats()
            messagebox.showinfo("Delete", "File removed. No more data files in this folder.")
            return

        if self._index >= len(self._files):
            self._index = len(self._files) - 1
        self._file_combo.configure(values=[self._display_path(p) for p in self._files])
        self._sync_file_combo()
        self._load_current_file()

    @staticmethod
    def _format_hover_value(v: float) -> str:
        if not np.isfinite(v):
            return "—"
        av = abs(v)
        if av != 0.0 and (av < 1e-3 or av >= 1e5):
            return f"{v:.4g}"
        if av >= 100.0:
            return f"{v:.2f}"
        if av >= 1.0:
            return f"{v:.4f}"
        return f"{v:.5g}"

    def _teardown_hover(self) -> None:
        for cid in self._hover_cids:
            try:
                self._canvas.mpl_disconnect(cid)
            except Exception:
                pass
        self._hover_cids = []
        self._hover_track = []

    def _on_hover_motion(self, event) -> None:
        track = self._hover_track
        if not track:
            return
        for h in track:
            h["vline"].set_visible(False)
            h["ann"].set_visible(False)
        if event.inaxes is None or event.xdata is None or not np.isfinite(float(event.xdata)):
            self._canvas.draw_idle()
            return
        h = next((x for x in track if x["ax"] is event.inaxes), None)
        if h is None:
            self._canvas.draw_idle()
            return
        xq = float(event.xdata)
        yq = interp_y_at_time(h["t"], h["y"], xq)
        ax = h["ax"]
        ylim = ax.get_ylim()
        h["vline"].set_data([xq, xq], ylim)
        h["vline"].set_visible(True)
        tc = self._time_col or "t"
        h["ann"].set_text(
            f"{tc} = {self._format_hover_value(xq)}\n{h['col']} = {self._format_hover_value(yq)}"
        )
        h["ann"].set_visible(True)
        self._canvas.draw_idle()

    def _on_hover_leave_figure(self, _event) -> None:
        for h in self._hover_track or []:
            h["vline"].set_visible(False)
            h["ann"].set_visible(False)
        self._canvas.draw_idle()

    def _redraw(self) -> None:
        self._teardown_hover()
        self._fig.clear()
        if self._df is None or self._time_col is None:
            self._active_lbl.configure(text="(no data)")
            ax = self._fig.add_subplot(1, 1, 1)
            ax.text(0.5, 0.5, "No data loaded", ha="center", va="center")
            self._canvas.draw()
            return

        active = self._compute_active_region_summary()
        df = self._df
        t = pd.to_numeric(df[self._time_col], errors="coerce")
        xlim = self._effective_xlim()

        if not self._y_cols:
            ax = self._fig.add_subplot(1, 1, 1)
            ax.text(0.5, 0.5, "No plottable numeric columns", ha="center", va="center")
            self._canvas.draw()
            return

        show = self._visible_cols()
        if not show:
            ax = self._fig.add_subplot(1, 1, 1)
            ax.text(
                0.5, 0.5,
                "No graphs selected — enable one in the 'Graphs' panel above.",
                ha="center", va="center",
            )
            self._canvas.draw()
            return

        n = len(show)
        axes = self._fig.subplots(n, 1, sharex=True, squeeze=False)
        self._fig.suptitle(
            f"{self._title_lbl.cget('text')}  —  time: {self._time_col}",
            fontsize=11,
        )

        hover_track: list[dict] = []
        for i, col in enumerate(show):
            ax = axes[i, 0]
            y = pd.to_numeric(df[col], errors="coerce")
            mask = np.isfinite(t) & np.isfinite(y)
            if mask.any():
                ax.plot(t.values[mask], y.values[mask], linewidth=0.8)
            t_v = t.values[mask] if bool(mask.any()) else np.array([], dtype=float)
            y_v = y.values[mask] if bool(mask.any()) else np.array([], dtype=float)
            ax.set_ylabel(col, fontsize=9)
            ax.grid(True, alpha=0.3)
            ax.set_xlim(xlim)
            if (
                active is not None
                and "t_start" in active
                and "t_stop" in active
            ):
                t0, t1 = float(active["t_start"]), float(active["t_stop"])
                if col == "i_motor" and active.get("mean_i_motor") is not None:
                    m = float(active["mean_i_motor"])
                    ax.hlines(
                        m,
                        t0,
                        t1,
                        colors="darkorange",
                        linestyles="--",
                        linewidth=1.4,
                        zorder=3,
                    )
                if col == "i_in" and active.get("mean_i_in") is not None:
                    m = float(active["mean_i_in"])
                    ax.hlines(
                        m,
                        t0,
                        t1,
                        colors="darkviolet",
                        linestyles="--",
                        linewidth=1.4,
                        zorder=3,
                    )
            if (
                active is not None
                and col == active.get("pos_col")
                and "t_start" in active
                and "t_stop" in active
            ):
                t0, t1 = float(active["t_start"]), float(active["t_stop"])
                ax.axvspan(t0, t1, color="C0", alpha=0.12, zorder=0)
                ax.axvline(t0, color="seagreen", ls="--", lw=1.0, zorder=2)
                ax.axvline(t1, color="firebrick", ls="--", lw=1.0, zorder=2)
                dtp = f"{active['duration_s']:.3f} s"
                lines: list[str] = [f"active Δt = {dtp}"]
                if active.get("mean_i_motor") is not None:
                    lines.append(f"avg i_motor = {active['mean_i_motor']:.3f} A")
                if active.get("mean_i_in") is not None:
                    lines.append(f"avg i_in = {active['mean_i_in']:.3f} A")
                ax.text(
                    0.02,
                    0.98,
                    "\n".join(lines),
                    transform=ax.transAxes,
                    va="top",
                    ha="left",
                    fontsize=8,
                    bbox=dict(boxstyle="round,pad=0.35", facecolor="wheat", alpha=0.88),
                    zorder=4,
                )
            vline, = ax.plot(
                [float("nan"), float("nan")],
                [float("nan"), float("nan")],
                color="0.2",
                ls="--",
                lw=0.95,
                zorder=50,
                visible=False,
            )
            ann = ax.text(
                0.98,
                0.98,
                "",
                transform=ax.transAxes,
                va="top",
                ha="right",
                fontsize=7,
                zorder=51,
                visible=False,
                family="monospace",
                bbox=dict(boxstyle="round,pad=0.25", facecolor="white", edgecolor="0.45", alpha=0.92),
            )
            hover_track.append(
                {"ax": ax, "t": t_v, "y": y_v, "col": col, "vline": vline, "ann": ann}
            )

        self._hover_track = hover_track
        if hover_track:
            self._hover_cids = [
                self._canvas.mpl_connect("motion_notify_event", self._on_hover_motion),
                self._canvas.mpl_connect("figure_leave_event", self._on_hover_leave_figure),
            ]

        axes[-1, 0].set_xlabel(self._time_col)
        self._canvas.draw()


def main() -> None:
    app = DataCaptureViewer()
    app.mainloop()


if __name__ == "__main__":
    main()
